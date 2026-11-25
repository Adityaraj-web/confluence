// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {MakerVenue} from "./libraries/MakerVenue.sol";
import {PoolVenue} from "./libraries/PoolVenue.sol";
import {SplitMath} from "./libraries/SplitMath.sol";

/// @notice Leg status codes of the `ConfluenceSwap` event (ARCHITECTURE-v2 section 7, D-35). Codes 0-7 are the
///         section's list in its order; 8 and 9 were added by V2-07.
library LegStatus {
    /// @dev The leg filled.
    uint8 internal constant FILLED = 0;
    /// @dev The router call reverted (docked, drained, revoked, refused by the guard, out of gas).
    uint8 internal constant SKIP_REVERT = 1;
    /// @dev The band leaves no room for a fill (V2-06).
    uint8 internal constant SKIP_BAND = 2;
    /// @dev Snapshot and EMA are further apart than the maker's `driftTicks`.
    uint8 internal constant SKIP_DRIFT = 3;
    /// @dev Unshipped, docked, rebuilt bytes not the registered ones, or the wallet, allowance or PoolManager leaves
    ///      less than the smallest fill.
    uint8 internal constant SKIP_UNDERFUNDED = 4;
    /// @dev The solve gave the maker nothing, less than its smallest fill or `MIN_LEG_BPS`, or it was not among the
    ///      `MAX_LEGS` largest; or the PoolManager's balance trimmed it below its smallest fill.
    uint8 internal constant SKIP_MIN_LEG = 5;
    /// @dev Not enough gas left for the plan or the leg.
    uint8 internal constant SKIP_GAS = 6;
    /// @dev Reserves or fee outside the maths envelope.
    uint8 internal constant SKIP_MATH = 7;
    /// @dev The split was not provably at least the pool alone, so the whole swap went to the pool.
    uint8 internal constant SKIP_NOT_BETTER = 8;
    /// @dev The splitter failed, ran out of gas, returned malformed data, or its plan failed one of the hook's checks.
    uint8 internal constant SKIP_PLAN = 9;
    /// @dev The largest code.
    uint8 internal constant MAX_CODE = 9;
}

/// @notice One swap's split, as `ConfluenceSplitter.planExactIn` returns it. Fully static (`PLAN_WORDS` words), so a
///         return of exactly that many bytes always decodes. Index `i` of every array is slot `i` of the pool's
///         registry (`ConfluenceHook.strategiesOf`); entries past the registry are zero.
/// @param poolIn The pool's share of the input.
/// @param status Per slot: `LegStatus.FILLED` for a planned leg, else why the maker has none.
/// @param amountIn Per slot: the leg's gross input, 0 for no leg.
/// @param amountOut Per slot: the leg's exact output (SwapVM's rounding), used as the router's strict threshold.
/// @param capMin Per slot: the smallest gross input the guard accepts (V2-06), as read.
/// @param capIn Per slot: the largest gross input (band, wallet, allowance, PoolManager), as read.
/// @param poolOut The pool's output for `poolIn`, over the walked segments.
/// @param poolOnlyOut The pool's output for the whole input, over the walked segments.
/// @param tail An upper bound on what the pool gives past a truncated walk; 0 at a hard end.
/// @param walked The input the walked segments take (the sum of their `capIn`).
/// @param truncated 1 if the walk stopped before the swap's price limit, else 0.
struct Plan {
    uint256 poolIn;
    uint256[6] status;
    uint256[6] amountIn;
    uint256[6] amountOut;
    uint256[6] capMin;
    uint256[6] capIn;
    uint256 poolOut;
    uint256 poolOnlyOut;
    uint256 tail;
    uint256 walked;
    uint256 truncated;
}

/// @dev The hook's views the splitter reads back.
interface IConfluenceHookView {
    function poolManager() external view returns (IPoolManager);
    function bandGuard() external view returns (address);
    function strategiesOf(PoolId poolId) external view returns (MakerVenue.Entry[] memory);
}

/// @title ConfluenceSplitter
/// @notice Plans one exact-input swap for `ConfluenceHook` (V2-07, D-35): reads the pool (`PoolVenue`) and every
///         registered maker (`MakerVenue`) at the hook's post-update anchor, solves the best split (`SplitMath`),
///         keeps at most `MAX_LEGS` legs of at least `MIN_LEG_BPS` and the maker's smallest fill, trims them to the
///         PoolManager's balance, and quotes the pool for the hook's never-worse check.
/// @dev Stateless and immutable: no storage, no immutables, no owner, one external `view`. It exists because the hook
///      and these libraries do not fit in one contract (EIP-170). The hook passes its address in its constructor and
///      checks the plan it returns (D-35); verifying the hook includes verifying this contract.
contract ConfluenceSplitter {
    using PoolIdLibrary for PoolKey;

    /// @notice Most maker legs per swap (each is one router call).
    uint256 public constant MAX_LEGS = 3;
    /// @notice Smallest leg, in basis points of the swap's input.
    uint256 public constant MIN_LEG_BPS = 50;
    /// @notice Solves per plan: the first, and one more after dropping legs. Dropping a venue lowers the level, so
    ///         the remaining shares only grow; a second drop round is applied without solving again (D-35).
    uint256 public constant MAX_SOLVES = 2;
    /// @notice Words in an encoded `Plan`.
    uint256 public constant PLAN_WORDS = 36;

    uint256 private constant BPS = 10_000;
    uint256 private constant PIPS = 1e6;
    uint256 private constant Q96 = 2 ** 96;

    /// @notice The split of `amountIn` for a swap on `key` in direction `zeroForOne` with the swap's own price limit,
    ///         at the anchor (`snapTick`, `emaTickX`) the hook stored for this block. Anyone may call (it is a view);
    ///         `ConfluenceHook.beforeSwap` calls it with a gas cap and checks the result.
    /// @dev Reads the registry, the guard and the PoolManager back from `key.hooks`. Sets every planned leg to
    ///      `FILLED` and every other slot to its skip code. If its own never-worse check fails, every leg becomes
    ///      `SKIP_NOT_BETTER` and the pool takes everything.
    function planExactIn(
        PoolKey calldata key,
        bool zeroForOne,
        uint160 sqrtPriceLimitX96,
        uint256 amountIn,
        int24 snapTick,
        int56 emaTickX
    ) external view returns (Plan memory p) {
        IConfluenceHookView h = IConfluenceHookView(address(key.hooks));
        IPoolManager pm = h.poolManager();
        PoolId id = key.toId();
        PoolVenue.Pool memory pool = PoolVenue.read(pm, id, key.tickSpacing, zeroForOne, sqrtPriceLimitX96);
        MakerVenue.Maker[] memory ms =
            MakerVenue.read(pm, key, h.bandGuard(), h.strategiesOf(id), zeroForOne, snapTick, emaTickX);

        uint256 n = Math.min(ms.length, MakerVenue.MAX_MAKERS);
        bool[] memory live = new bool[](ms.length);
        for (uint256 i; i < n; i++) {
            p.capMin[i] = ms[i].capMin;
            p.capIn[i] = ms[i].capIn;
            p.status[i] = _code(ms[i].status);
            live[i] = ms[i].status == MakerVenue.Status.OK;
        }

        // Solve, drop, solve again once.
        SplitMath.Venue[] memory pv = PoolVenue.venues(pool, true);
        uint256[] memory a;
        uint256[] memory idx;
        for (uint256 s; s < MAX_SOLVES; s++) {
            SplitMath.Venue[] memory mv;
            (mv, idx) = _venues(ms, live);
            (a,) = SplitMath.solveExactIn(pv, mv, amountIn);
            if (!_drop(ms, live, idx, a, amountIn, p)) break;
        }
        _legs(ms, live, idx, a, amountIn, Currency.unwrap(zeroForOne ? key.currency0 : key.currency1), pm, p);

        _quotes(pool, amountIn, p);
        if (p.poolIn == amountIn) return p;
        bool better = !(pool.truncated && p.poolIn > p.walked);
        if (better) {
            uint256 makersOut = 0;
            for (uint256 i; i < n; i++) {
                makersOut += p.amountOut[i];
            }
            better = p.poolOut + makersOut >= p.poolOnlyOut + p.tail;
        }
        if (!better) {
            for (uint256 i; i < n; i++) {
                if (p.amountIn[i] == 0) continue;
                p.status[i] = LegStatus.SKIP_NOT_BETTER;
                p.amountIn[i] = 0;
                p.amountOut[i] = 0;
            }
            p.poolIn = amountIn;
            (p.poolOut,,) = PoolVenue.quoteExactIn(pool, amountIn);
        }
    }

    /// @notice STUB (V2-08 red step): exact-output plan; for now pool-only.
    function planExactOut(PoolKey calldata, bool, uint160, uint256 amountOut, int24, int56)
        external
        pure
        returns (Plan memory p)
    {
        p.poolIn = amountOut;
    }

    /// @dev The live makers as SplitMath venues, capped at `capIn`, and their slot indices.
    function _venues(MakerVenue.Maker[] memory ms, bool[] memory live)
        private
        pure
        returns (SplitMath.Venue[] memory v, uint256[] memory index)
    {
        uint256 len = Math.min(ms.length, MakerVenue.MAX_MAKERS);
        uint256 k = 0;
        for (uint256 i; i < len; i++) {
            if (live[i]) k++;
        }
        v = new SplitMath.Venue[](k);
        index = new uint256[](k);
        k = 0;
        for (uint256 i; i < len; i++) {
            if (!live[i]) continue;
            v[k] = SplitMath.Venue({x: ms[i].x, y: ms[i].y, feeE9: ms[i].feeE9, cap: ms[i].capIn});
            index[k++] = i;
        }
    }

    /// @dev Drops shares that are zero, under the maker's smallest fill or under `MIN_LEG_BPS`, then all but the
    ///      `MAX_LEGS` largest. True if any was dropped.
    function _drop(
        MakerVenue.Maker[] memory ms,
        bool[] memory live,
        uint256[] memory idx,
        uint256[] memory a,
        uint256 amount,
        Plan memory p
    ) private pure returns (bool dropped) {
        uint256 kept = 0;
        uint256 m = Math.min(idx.length, MakerVenue.MAX_MAKERS);
        for (uint256 j; j < m; j++) {
            uint256 i = idx[j];
            if (_tooSmall(a[j + 1], ms[i].capMin, amount)) {
                live[i] = false;
                p.status[i] = LegStatus.SKIP_MIN_LEG;
                dropped = true;
            } else {
                kept++;
            }
        }
        for (uint256 r = 0; r < MakerVenue.MAX_MAKERS && kept > MAX_LEGS; r++) {
            uint256 worst = type(uint256).max;
            uint256 at = 0;
            for (uint256 j; j < m; j++) {
                if (live[idx[j]] && a[j + 1] < worst) (worst, at) = (a[j + 1], idx[j]);
            }
            live[at] = false;
            p.status[at] = LegStatus.SKIP_MIN_LEG;
            kept--;
            dropped = true;
        }
    }

    /// @dev The final legs: the last solve's shares of the makers still live, largest first, each trimmed to what is
    ///      left of the PoolManager's balance of the input token (the hook takes the total from it before the trader
    ///      pays). A leg trimmed under its smallest fill or `MIN_LEG_BPS` is dropped. The pool takes the rest.
    function _legs(
        MakerVenue.Maker[] memory ms,
        bool[] memory live,
        uint256[] memory idx,
        uint256[] memory a,
        uint256 amount,
        address tokenIn,
        IPoolManager pm,
        Plan memory p
    ) private view {
        uint256 pmLeft = IERC20(tokenIn).balanceOf(address(pm));
        uint256 sumIn = 0;
        uint256 m = Math.min(idx.length, MakerVenue.MAX_MAKERS);
        for (uint256 r; r < MakerVenue.MAX_MAKERS; r++) {
            uint256 best = 0;
            uint256 at = type(uint256).max;
            for (uint256 j; j < m; j++) {
                uint256 i = idx[j];
                if (live[i] && p.amountIn[i] == 0 && a[j + 1] > best) (best, at) = (a[j + 1], i);
            }
            if (at == type(uint256).max) break;
            live[at] = false; // handled
            uint256 x = Math.min(best, pmLeft);
            if (_tooSmall(x, ms[at].capMin, amount)) {
                p.status[at] = LegStatus.SKIP_MIN_LEG;
                continue;
            }
            (, uint256 o) = MakerVenue.quoteExactIn(ms[at], x);
            p.amountIn[at] = x;
            p.amountOut[at] = o;
            p.status[at] = LegStatus.FILLED;
            pmLeft -= x;
            sumIn += x;
        }
        p.poolIn = amount - sumIn;
    }

    /// @dev The pool quotes for the never-worse check (carry-overs 5 and 6). `tail` bounds from above what the pool
    ///      gives past a truncated walk: the rest of the input, net of the fee, at the price where the walk stopped,
    ///      rounded up. The pool's rate never rises along a swap, so the real tail is at most that.
    function _quotes(PoolVenue.Pool memory pool, uint256 amount, Plan memory p) private pure {
        uint256 len = pool.segments.length;
        for (uint256 i = 0; i < len && i < PoolVenue.MAX_TICK_RANGES; i++) {
            p.walked += pool.segments[i].capIn;
        }
        p.truncated = pool.truncated ? 1 : 0;
        (p.poolOut,,) = PoolVenue.quoteExactIn(pool, p.poolIn);
        uint256 used;
        (p.poolOnlyOut, used,) = PoolVenue.quoteExactIn(pool, amount);
        if (pool.truncated && used < amount && len > 0) {
            uint256 s = pool.segments[len - 1].sqrtPriceEndX96;
            uint256 rest = Math.mulDiv(amount - used, PIPS - pool.swapFee, PIPS, Math.Rounding.Ceil);
            p.tail = pool.zeroForOne
                ? FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(rest, s, Q96), s, Q96)
                : FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(rest, Q96, s), Q96, s);
        }
    }

    function _tooSmall(uint256 x, uint256 capMin, uint256 amount) private pure returns (bool) {
        return x == 0 || x < capMin || x * BPS < amount * MIN_LEG_BPS;
    }

    function _code(MakerVenue.Status s) private pure returns (uint256) {
        if (s == MakerVenue.Status.OK) return LegStatus.FILLED;
        if (s == MakerVenue.Status.SKIP_BAND) return LegStatus.SKIP_BAND;
        if (s == MakerVenue.Status.SKIP_DRIFT) return LegStatus.SKIP_DRIFT;
        if (s == MakerVenue.Status.SKIP_UNDERFUNDED) return LegStatus.SKIP_UNDERFUNDED;
        return LegStatus.SKIP_MATH;
    }
}
