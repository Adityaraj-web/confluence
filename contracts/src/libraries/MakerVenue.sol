// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {StrategyTemplate} from "./StrategyTemplate.sol";
import {SplitMath} from "./SplitMath.sol";

/// @title MakerVenue
/// @notice Turns each registered template-T1 strategy into a venue with honest reserves and a cap, before any money
///         moves (V2-06, ARCHITECTURE-v2 section 2 step 3). View only, never reverts for a registered maker, every
///         loop bounded by `MAX_MAKERS`.
/// @dev The maker's curve is SwapVM's: a flat fee that takes `ceil(a * fee / 1e9)` off the input (`Fee.sol:86-91`), then
///      XYC `out = floor(net * Y / (X + net))` (`XYCSwap.sol:22-25`). `BandGuardV2` sees the net input and the floored
///      output. The caps keep every fill the hook can size inside what Aqua can pull, what the PoolManager can give,
///      and what the guard will accept (D-34):
///        - output cap: `min(virtual Y, wallet, allowance to Aqua)` (`real`, shared with V2-05's depth), inverted
///          through the curve and the fee exactly;
///        - band cap: a closed-form margin below the real-number band edge, proved with a convexity argument;
///        - PoolManager cap: the PoolManager's balance of the input token.
library MakerVenue {
    /// @notice Why a maker contributes nothing (ARCHITECTURE-v2 section 7 codes) or `OK`.
    enum Status {
        OK,
        SKIP_BAND,
        SKIP_DRIFT,
        SKIP_UNDERFUNDED,
        SKIP_MATH
    }

    /// @notice A registered maker as the hook stores it (same fields as `ConfluenceHook.Slot`).
    struct Entry {
        address maker;
        StrategyTemplate.Params params;
        bytes32 strategyHash;
    }

    /// @notice One maker as a venue. `x` is the virtual balance of the input token and `y` of the output token. Every
    ///         fill of gross input in `[capMin, capIn]` passes the guard, stays inside the output cap and the
    ///         PoolManager's balance; `capOut` is the output at `capIn`. All zero unless `status` is `OK`, except
    ///         `maker`, `strategyHash`, `status`, and `x`, `y`, `feeE9` once they were read.
    struct Maker {
        address maker;
        bytes32 strategyHash;
        Status status;
        uint256 x;
        uint256 y;
        uint32 feeE9;
        uint256 capMin;
        uint256 capIn;
        uint256 capOut;
    }

    /// @notice Most makers one read takes (the hook's `MAX_STRATEGIES`; a test asserts they are equal).
    uint256 internal constant MAX_MAKERS = 6;
    /// @notice Aqua and the canonical router, as in the hook (a test asserts they are equal).
    address internal constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    address internal constant ROUTER = 0x111111338c5091E8440b67B168bAe16a668AC0De;

    uint256 private constant B = 1e9;
    uint256 private constant MAX_AMOUNT = type(uint128).max;
    uint8 private constant _DOCKED = 0xff;
    uint8 private constant _TOKENS = 2;
    uint256 private constant X192_SQRT_LIMIT = 2 ** 127;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant TICK_SCALE = 2 ** 16;

    /// @notice What Aqua can pull of one token: the virtual balance, capped by the wallet and the allowance to Aqua.
    ///         The one function behind both V2-05's depth and V2-06's cap (carry-over 1).
    function real(address token, address maker, uint256 virtualBalance) internal view returns (uint256) {
        // forge-lint: disable-next-line(calls-loop)
        return Math.min(virtualBalance, Math.min(IERC20(token).balanceOf(maker), IERC20(token).allowance(maker, AQUA)));
    }

    /// @notice All registered makers as venues for an EXACT-INPUT swap in the given direction. `snapTick` and
    ///         `emaTickX` must be the anchor `BandGuardV2` reads via `anchorOfX` in the same swap (the post-update
    ///         values).
    /// @dev Reads the PoolManager's balance of the input token once. Never reverts for registered makers.
    function read(
        IPoolManager manager,
        PoolKey memory key,
        address guard,
        Entry[] memory entries,
        bool zeroForOne,
        int24 snapTick,
        int56 emaTickX
    ) internal view returns (Maker[] memory) {
        return _readAll(manager, key, guard, entries, zeroForOne, snapTick, emaTickX, false);
    }

    /// @notice The same for an EXACT-OUTPUT swap (V2-08, D-36). The caps are in OUTPUT units: `capMin` is the smallest
    ///         and `capOut` the largest output of one fill that passes the guard, the output cap and the PoolManager's
    ///         balance; `capIn` is the gross input of the fill at `capOut`.
    function readOut(
        IPoolManager manager,
        PoolKey memory key,
        address guard,
        Entry[] memory entries,
        bool zeroForOne,
        int24 snapTick,
        int56 emaTickX
    ) internal view returns (Maker[] memory) {
        return _readAll(manager, key, guard, entries, zeroForOne, snapTick, emaTickX, true);
    }

    function _readAll(
        IPoolManager manager,
        PoolKey memory key,
        address guard,
        Entry[] memory entries,
        bool zeroForOne,
        int24 snapTick,
        int56 emaTickX,
        bool exactOut
    ) private view returns (Maker[] memory out) {
        uint256 n = Math.min(entries.length, MAX_MAKERS);
        out = new Maker[](n);
        address tokenIn = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        // forge-lint: disable-next-line(calls-loop)
        uint256 pmBalance = IERC20(tokenIn).balanceOf(address(manager));
        for (uint256 i; i < n; i++) {
            out[i] = _readOne(manager, key, guard, entries[i], zeroForOne, snapTick, emaTickX, pmBalance, exactOut);
        }
    }

    /// @notice One maker as a venue. See `Maker` and the contract notes.
    function readOne(
        IPoolManager manager,
        PoolKey memory key,
        address guard,
        Entry memory e,
        bool zeroForOne,
        int24 snapTick,
        int56 emaTickX,
        uint256 pmBalanceIn
    ) internal view returns (Maker memory) {
        return _readOne(manager, key, guard, e, zeroForOne, snapTick, emaTickX, pmBalanceIn, false);
    }

    function _readOne(
        IPoolManager manager,
        PoolKey memory key,
        address guard,
        Entry memory e,
        bool zeroForOne,
        int24 snapTick,
        int56 emaTickX,
        uint256 pmBalanceIn,
        bool exactOut
    ) private view returns (Maker memory m) {
        m.maker = e.maker;
        m.strategyHash = e.strategyHash;
        // The drift check needs no external call, so it goes first.
        if (!driftPasses(snapTick, emaTickX, e.params.driftTicks)) {
            m.status = Status.SKIP_DRIFT;
            return m;
        }
        // Rebuild the order from the registered parameters; the stored hash is only compared, never priced from
        // (carry-over 4). A mismatch means Aqua would not know these bytes, so the maker is dead for this swap.
        bytes32 h = StrategyTemplate.strategyHash(
            StrategyTemplate.order(e.maker, StrategyTemplate.program(e.params, manager, key, guard))
        );
        if (h != e.strategyHash) {
            m.status = Status.SKIP_UNDERFUNDED;
            return m;
        }
        address tokenIn = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        address tokenOut = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);
        // `rawBalances` never reverts and its count tells shipped (2) from unshipped (0) and docked (0xff);
        // `safeBalances`, which the router uses, would revert for the last two (`Aqua.sol:30-35`).
        // forge-lint: disable-start(calls-loop, unused-return)
        (uint256 x, uint8 nIn) = IAqua(AQUA).rawBalances(e.maker, ROUTER, h, tokenIn);
        (uint256 y, uint8 nOut) = IAqua(AQUA).rawBalances(e.maker, ROUTER, h, tokenOut);
        // forge-lint: disable-end(calls-loop, unused-return)
        if (nIn != _TOKENS || nOut != _TOKENS) {
            m.status = Status.SKIP_UNDERFUNDED;
            return m;
        }
        m.x = x;
        m.y = y;
        m.feeE9 = e.params.feeE9;
        uint256 outCap = real(tokenOut, e.maker, y);
        if (exactOut) {
            (m.status, m.capMin, m.capOut, m.capIn) =
                capsOut(x, y, e.params.feeE9, outCap, pmBalanceIn, snapTick, zeroForOne, e.params.bandBps);
        } else {
            (m.status, m.capMin, m.capIn, m.capOut) =
                caps(x, y, e.params.feeE9, outCap, pmBalanceIn, snapTick, zeroForOne, e.params.bandBps);
        }
    }

    /// @notice The pure core of `readOne`: status and caps from reserves `x`, `y`, the fee, the real output cap
    ///         `outCap` (`real` of the output token), the PoolManager's balance of the input token, and the guard's
    ///         inputs (snapshot, direction, band). Never reverts.
    function caps(
        uint256 x,
        uint256 y,
        uint32 feeE9,
        uint256 outCap,
        uint256 pmBalanceIn,
        int24 snapTick,
        bool zeroIn,
        uint16 bandBps
    ) internal pure returns (Status status, uint256 capMin, uint256 capIn, uint256 capOut) {
        if (feeE9 >= B || x > MAX_AMOUNT || y > MAX_AMOUNT) return (Status.SKIP_MATH, 0, 0, 0);
        if (x == 0 || y == 0 || outCap == 0 || pmBalanceIn == 0) return (Status.SKIP_UNDERFUNDED, 0, 0, 0);

        Band memory band = _band(snapTick, zeroIn, bandBps);
        if (!_startInBand(band, x, y)) return (Status.SKIP_BAND, 0, 0, 0);
        (bool ok, uint256 nMin, uint256 nMax) = _bandRange(band, x, y);
        if (!ok) return (Status.SKIP_BAND, 0, 0, 0);

        capMin = _grossMin(nMin, feeE9);
        uint256 gBand = _grossMax(nMax, feeE9);
        // Output cap: the largest net with out <= outCap, then the largest gross with that net.
        uint256 gOut = MAX_AMOUNT;
        if (outCap + 1 < y) {
            uint256 nOut = Math.ceilDiv((outCap + 1) * x, y - outCap - 1) - 1;
            gOut = _grossMax(Math.min(nOut, MAX_AMOUNT), feeE9);
        }
        uint256 capOther = Math.min(Math.min(gOut, pmBalanceIn), MAX_AMOUNT);
        capIn = Math.min(gBand, capOther);
        if (capIn < capMin) {
            // Nothing fits: the wallet, allowance or PoolManager leaves less than the guard's smallest fill, or the
            // band itself leaves no room.
            status = capOther < capMin ? Status.SKIP_UNDERFUNDED : Status.SKIP_BAND;
            return (status, 0, 0, 0);
        }
        (, capOut) = quoteExactIn(_maker(x, y, feeE9), capIn);
    }

    /// @notice Exact output of a fill of gross input `a` on this maker: fee rounded up, then XYC rounded down. Returns
    ///         the net input too. Equals what SwapVM computes, to the wei.
    function quoteExactIn(Maker memory m, uint256 a) internal pure returns (uint256 net, uint256 out) {
        // net = a - ceil(a * fee / 1e9) = floor(a * (1e9 - fee) / 1e9)  (Fee.sol:86-91)
        net = a - Math.mulDiv(a, m.feeE9, B, Math.Rounding.Ceil);
        // out = floor(net * y / (x + net))  (XYCSwap.sol:22-25)
        out = net == 0 ? 0 : Math.mulDiv(net, m.y, m.x + net);
    }

    /// @notice Exact-output caps (V2-08, D-36): the smallest and largest OUTPUT `bMin <= bMax` such that every exact-output
    ///         fill of `b` in between passes the guard, stays inside `outCap` (`real` of the output token) and costs no
    ///         more gross input than `pmBalanceIn`; `aMax` is the gross input of the fill at `bMax`. Never reverts.
    /// @dev SwapVM's exact output (`XYCSwap.sol:26-31`, `Fee.sol:92-96`): the guard sees the NET input
    ///      `n(b) = ceil(b x / (y - b))` and the exact output `b`; the fee is grossed up afterwards, out of the guard's
    ///      sight. With `N(b) = b x + y - b - 1` we have `n(b) <= N(b) / (y - b)` for every `b`, so the guard passes
    ///      whenever (token0 in, `c = lo / 2^s`)  `2^s b (y - b) >= lo N(b)`  or (token1 in, `c = 2^s / (hi + 1)`)
    ///      `(hi + 1) b (y - b) > 2^s N(b)`. Both differences are concave quadratics in `b`, so if they hold at `bMin` and
    ///      `bMax` they hold for every `b` between. The ends are placed from the real edge `b_r = y - c x` with a margin
    ///      `m = 4 ceil(c y / b_r) + 2` (`bMin = m`, `bMax = b_r - m`; first-order roots, times four) and verified
    ///      exactly in 512 bits; a miss gives `SKIP_BAND`, so the factor of four only decides liquidity lost, never
    ///      safety. Lowering `bMax` for the other caps keeps the proof (concavity). The PoolManager cap is the output
    ///      of an exact-input fill of `pmBalanceIn`: its exact-output gross is at most `pmBalanceIn`, and gross rises
    ///      with `b`.
    function capsOut(
        uint256 x,
        uint256 y,
        uint32 feeE9,
        uint256 outCap,
        uint256 pmBalanceIn,
        int24 snapTick,
        bool zeroIn,
        uint16 bandBps
    ) internal pure returns (Status status, uint256 bMin, uint256 bMax, uint256 aMax) {
        if (feeE9 >= B || x > MAX_AMOUNT || y > MAX_AMOUNT) return (Status.SKIP_MATH, 0, 0, 0);
        if (x == 0 || y == 0 || outCap == 0 || pmBalanceIn == 0) return (Status.SKIP_UNDERFUNDED, 0, 0, 0);

        Band memory band = _band(snapTick, zeroIn, bandBps);
        if (!_startInBand(band, x, y)) return (Status.SKIP_BAND, 0, 0, 0);
        bool ok;
        (ok, bMin, bMax) = _bandRangeOut(band, x, y);
        if (!ok) return (Status.SKIP_BAND, 0, 0, 0);

        Maker memory m = _maker(x, y, feeE9);
        (, uint256 bPm) = quoteExactIn(m, Math.min(pmBalanceIn, MAX_AMOUNT));
        uint256 other = Math.min(Math.min(outCap, y - 1), bPm);
        bMax = Math.min(bMax, other);
        if (bMax < bMin) {
            return (other < bMin ? Status.SKIP_UNDERFUNDED : Status.SKIP_BAND, 0, 0, 0);
        }
        (, aMax) = quoteExactOut(m, bMax);
    }

    /// @notice Exact input of a fill of output `b` on this maker (`b < y`): XYC rounded up, then the fee grossed up,
    ///         rounded up. Returns the net input too. Equals what SwapVM computes, to the wei. For `b >= y` returns the
    ///         maximum (no such fill exists).
    function quoteExactOut(Maker memory m, uint256 b) internal pure returns (uint256 net, uint256 gross) {
        if (b >= m.y) return (type(uint256).max, type(uint256).max);
        // net = ceil(b x / (y - b))  (XYCSwap.sol:28-31)
        net = Math.mulDiv(b, m.x, m.y - b, Math.Rounding.Ceil);
        // gross = net + ceil(net fee / (1e9 - fee))  (Fee.sol:95)
        gross = net + Math.mulDiv(net, m.feeE9, B - m.feeE9, Math.Rounding.Ceil);
    }

    /// @notice The band predicate exactly as `BandGuardV2` evaluates it on a fill with net input `net` and output
    ///         `out` (V2-04 `_checkBand`), for a snapshot and band. Anyone may call (it is pure).
    function bandPasses(int24 snapTick, bool zeroIn, uint16 bandBps, uint256 net, uint256 out)
        internal
        pure
        returns (bool)
    {
        if (net == 0 || out == 0) return false; // BandNotComputed
        return _passes(_band(snapTick, zeroIn, bandBps), net, out);
    }

    /// @notice The drift predicate exactly as `BandGuardV2` evaluates it.
    function driftPasses(int24 snapTick, int56 emaTickX, uint16 driftTicks) internal pure returns (bool) {
        // TICK_SCALE is the constant 2^16, so the cast is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 gap = int256(snapTick) * int256(TICK_SCALE) - int256(emaTickX);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 distance = uint256(gap < 0 ? -gap : gap);
        return distance <= uint256(driftTicks) * TICK_SCALE;
    }

    /// @notice The live makers as `SplitMath` venues (cap = `capIn`, exact-input units) and each venue's index in `ms`.
    ///         Only the first `MAX_MAKERS` entries are looked at (`read` never returns more).
    function toVenues(Maker[] memory ms) internal pure returns (SplitMath.Venue[] memory v, uint256[] memory index) {
        uint256 len = Math.min(ms.length, MAX_MAKERS);
        uint256 n = 0;
        for (uint256 i = 0; i < len; i++) {
            if (ms[i].status == Status.OK) n++;
        }
        v = new SplitMath.Venue[](n);
        index = new uint256[](n);
        uint256 k = 0;
        for (uint256 i = 0; i < len; i++) {
            if (ms[i].status != Status.OK) continue;
            v[k] = SplitMath.Venue({x: ms[i].x, y: ms[i].y, feeE9: ms[i].feeE9, cap: ms[i].capIn});
            index[k] = i;
            k++;
        }
    }

    // ---------------------------------------------------------------- the guard's price maths, mirrored

    /// @dev The guard's reference price and band for a snapshot (`BandGuardV2._checkBand`): X192 below sqrt 2^127,
    ///      else X96. `lo = ref - lim`, `hi = ref + lim`.
    struct Band {
        bool zeroIn;
        uint256 shift;
        uint256 ref;
        uint256 lim;
        uint256 lo;
        uint256 hi;
    }

    function _band(int24 snapTick, bool zeroIn, uint16 bandBps) private pure returns (Band memory b) {
        uint256 s = TickMath.getSqrtPriceAtTick(snapTick);
        if (s < X192_SQRT_LIMIT) {
            b.shift = 192;
            b.ref = s * s;
        } else {
            b.shift = 96;
            b.ref = FullMath.mulDiv(s, s, 2 ** 96);
        }
        b.zeroIn = zeroIn;
        b.lim = FullMath.mulDiv(b.ref, bandBps, BPS_DENOMINATOR);
        b.lo = b.ref - b.lim;
        b.hi = b.ref + b.lim;
    }

    /// @dev `BandGuardV2._checkBand` on a fill with net input `n` and output `o` (both nonzero).
    function _passes(Band memory b, uint256 n, uint256 o) private pure returns (bool) {
        (uint256 num, uint256 den) = b.zeroIn ? (o, n) : (n, o);
        uint256 exec;
        if ((num >> (256 - b.shift)) >= den) exec = type(uint256).max;
        else exec = FullMath.mulDiv(num, 1 << b.shift, den);
        uint256 diff = exec > b.ref ? exec - b.ref : b.ref - exec;
        return diff <= b.lim;
    }

    /// @dev Whether the curve's starting price (reserves `x` in, `y` out, fee excluded: the guard sees the net input) is
    ///      inside the band, as real numbers. Outside it, the guard refuses every small fill, and a generous maker would
    ///      only pass for large fills, which a cap cannot express (D-34).
    function _startInBand(Band memory b, uint256 x, uint256 y) private pure returns (bool) {
        uint256 one = 1 << b.shift;
        if (b.zeroIn) return _mulLe(b.lo, x, y, one) && _mulLe(y, one, b.hi, x);
        return _mulLe(x, one, b.hi, y) && _mulLe(b.lo, y, x, one);
    }

    /// @dev `a * b <= c * d` in 512 bits.
    function _mulLe(uint256 a, uint256 b, uint256 c, uint256 d) private pure returns (bool) {
        (uint256 h1, uint256 l1) = Math.mul512(a, b);
        (uint256 h2, uint256 l2) = Math.mul512(c, d);
        return h1 < h2 || (h1 == h2 && l1 <= l2);
    }

    // ---------------------------------------------------------------- the band cap (D-34)

    /// @dev With `c = N / D` (token0 in: `(ref - lim) / 2^shift`; token1 in: `2^shift / (ref + lim + 1)`), a fill with net
    ///      input `n` passes the guard whenever the output `o = floor(n y / (x + n))` is at least `ceil(c n)` (token0
    ///      in) or `floor(c n) + 1` (token1 in); both are at most `c n + 1`. So `n y >= (c n + 1)(x + n)` is sufficient
    ///      for `n`, and its difference is concave in `n`: if it holds at two nets it holds for every net between them
    ///      (the guard's other side of the band follows from `_startInBand`). `_ok` checks the integer form
    ///      `ceil(c n) + 1 <= o`, which implies it.
    ///      The upper end starts from the real root `n_r = y / c - x` and backs off by `4 (x + n_r)^2 / (y n_r) + 2`: the
    ///      output floor costs one wei of output, which is `(x + n)^2 / (y n)` of net input, and `_ok`'s integer form
    ///      costs up to two more, so a factor of four leaves room; the lower end starts from the first-order root
    ///      `x / (y - c x - 1)`, times four plus two. Both ends are then verified exactly; a failure
    ///      drops the maker (`SKIP_BAND`), it never widens a cap.
    function _bandRange(Band memory b, uint256 x, uint256 y)
        private
        pure
        returns (bool ok, uint256 nMin, uint256 nMax)
    {
        (uint256 num, uint256 den) = b.zeroIn ? (b.lo, uint256(1) << b.shift) : (uint256(1) << b.shift, b.hi + 1);
        uint256 cx = _mulDivUp(num, x, den);
        if (cx >= y || y - cx <= 1) return (false, 0, 0);
        nMin = 4 * Math.ceilDiv(x, y - cx - 1) + 2;
        if (num == 0) {
            nMax = MAX_AMOUNT;
        } else {
            uint256 w = _mulDiv(y, den, num); // x + n_r, floored
            if (w >= x + MAX_AMOUNT) {
                nMax = MAX_AMOUNT; // the edge is beyond anything one leg can take
            } else {
                if (w <= x) return (false, 0, 0);
                uint256 nr = w - x;
                uint256 m = 4 * _mulDivUp(w, w, y * nr) + 2;
                if (m >= nr) return (false, 0, 0);
                nMax = nr - m;
            }
        }
        if (nMin > nMax || nMax > MAX_AMOUNT) return (false, 0, 0);
        ok = _ok(num, den, x, y, nMin) && _ok(num, den, x, y, nMax);
    }

    /// @dev `ceil(c n) + 1 <= floor(n y / (x + n))` for `c = num / den`.
    function _ok(uint256 num, uint256 den, uint256 x, uint256 y, uint256 n) private pure returns (bool) {
        uint256 q = _mulDivUp(num, n, den);
        if (q == type(uint256).max) return false;
        return q + 1 <= Math.mulDiv(n, y, x + n);
    }

    /// @dev The exact-output ends `[bMin, bMax]` for a band (see `capsOut`): placed from the real edge, then verified.
    function _bandRangeOut(Band memory b, uint256 x, uint256 y)
        private
        pure
        returns (bool ok, uint256 bMin, uint256 bMax)
    {
        (uint256 num, uint256 den) = b.zeroIn ? (b.lo, uint256(1) << b.shift) : (uint256(1) << b.shift, b.hi + 1);
        uint256 cx = _mulDivUp(num, x, den);
        if (cx >= y) return (false, 0, 0);
        uint256 edge = y - cx; // floor of the real edge b_r = y - c x
        uint256 cy = _mulDivUp(num, y, den);
        if (cy == type(uint256).max) return (false, 0, 0);
        uint256 m = 4 * Math.ceilDiv(cy, edge) + 2;
        if (m >= edge) return (false, 0, 0);
        (bMin, bMax) = (m, edge - m);
        ok = _okOut(b, x, y, bMin) && _okOut(b, x, y, bMax);
    }

    /// @dev The sufficient exact-output condition at `bb` (see `capsOut`), exact in 512 bits.
    function _okOut(Band memory b, uint256 x, uint256 y, uint256 bb) private pure returns (bool) {
        if (bb == 0 || bb >= y) return false;
        uint256 w = bb * (y - bb); // < 2^254
        uint256 n = bb * x + y - bb - 1; // < 2^256 for x, y <= MAX_AMOUNT
        uint256 one = uint256(1) << b.shift;
        if (b.zeroIn) return _mulLe(b.lo, n, one, w);
        return !_mulLe(b.hi + 1, w, one, n);
    }

    /// @dev Largest gross input whose net is at most `n`: `net(a) = floor(a (1e9 - fee) / 1e9)`, so
    ///      `a <= ceil((n + 1) 1e9 / (1e9 - fee)) - 1`. Clamped to `MAX_AMOUNT`.
    function _grossMax(uint256 n, uint32 feeE9) private pure returns (uint256) {
        return Math.min(Math.ceilDiv((n + 1) * B, B - feeE9) - 1, MAX_AMOUNT);
    }

    /// @dev Smallest gross input whose net is at least `n`: `a >= ceil(n 1e9 / (1e9 - fee))`.
    function _grossMin(uint256 n, uint32 feeE9) private pure returns (uint256) {
        return Math.ceilDiv(n * B, B - feeE9);
    }

    /// @dev `floor(a b / d)`, or the maximum when the result does not fit.
    function _mulDiv(uint256 a, uint256 b, uint256 d) private pure returns (uint256) {
        (uint256 hi,) = Math.mul512(a, b);
        if (hi >= d) return type(uint256).max;
        return Math.mulDiv(a, b, d);
    }

    /// @dev `ceil(a b / d)`, or the maximum when the result does not fit.
    function _mulDivUp(uint256 a, uint256 b, uint256 d) private pure returns (uint256) {
        uint256 r = _mulDiv(a, b, d);
        if (r == type(uint256).max) return r;
        return mulmod(a, b, d) == 0 ? r : r + 1;
    }

    function _maker(uint256 x, uint256 y, uint32 feeE9) private pure returns (Maker memory m) {
        m.x = x;
        m.y = y;
        m.feeE9 = feeE9;
    }
}
