// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
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

    /// @notice All registered makers as venues for a swap in the given direction. `snapTick` and `emaTickX` must be
    ///         the anchor `BandGuardV2` reads via `anchorOfX` in the same swap (the post-update values).
    /// @dev Reads the PoolManager's balance of the input token once. Never reverts for registered makers.
    function read(
        IPoolManager manager,
        PoolKey memory key,
        address guard,
        Entry[] memory entries,
        bool zeroForOne,
        int24 snapTick,
        int56 emaTickX
    ) internal view returns (Maker[] memory out) {
        uint256 n = Math.min(entries.length, MAX_MAKERS);
        out = new Maker[](n);
        address tokenIn = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        // forge-lint: disable-next-line(calls-loop)
        uint256 pmBalance = IERC20(tokenIn).balanceOf(address(manager));
        for (uint256 i; i < n; i++) {
            out[i] = readOne(manager, key, guard, entries[i], zeroForOne, snapTick, emaTickX, pmBalance);
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
    ) internal view returns (Maker memory m) {
        // STUB (red): filled in by the implementation commit.
        manager;
        key;
        guard;
        zeroForOne;
        snapTick;
        emaTickX;
        pmBalanceIn;
        m.maker = e.maker;
        m.strategyHash = e.strategyHash;
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
        x;
        y;
        feeE9;
        outCap;
        pmBalanceIn;
        snapTick;
        zeroIn;
        bandBps;
        status = Status.OK;
        capMin = 0;
        capIn = 0;
        capOut = 0;
    }

    /// @notice Exact output of a fill of gross input `a` on this maker: fee rounded up, then XYC rounded down. Returns
    ///         the net input too. Equals what SwapVM computes, to the wei.
    function quoteExactIn(Maker memory m, uint256 a) internal pure returns (uint256 net, uint256 out) {
        m;
        a;
        net = 0;
        out = 0;
    }

    /// @notice The band predicate exactly as `BandGuardV2` evaluates it on a fill with net input `net` and output
    ///         `out` (V2-04 `_checkBand`), for a snapshot and band. Anyone may call (it is pure).
    function bandPasses(int24 snapTick, bool zeroIn, uint16 bandBps, uint256 net, uint256 out)
        internal
        pure
        returns (bool)
    {
        snapTick;
        zeroIn;
        bandBps;
        net;
        out;
        return false;
    }

    /// @notice The drift predicate exactly as `BandGuardV2` evaluates it.
    function driftPasses(int24 snapTick, int56 emaTickX, uint16 driftTicks) internal pure returns (bool) {
        snapTick;
        emaTickX;
        driftTicks;
        return false;
    }

    /// @notice The live makers as `SplitMath` venues (cap = `capIn`, exact-input units) and each venue's index in `ms`.
    function toVenues(Maker[] memory ms) internal pure returns (SplitMath.Venue[] memory v, uint256[] memory index) {
        ms;
        v = new SplitMath.Venue[](0);
        index = new uint256[](0);
    }
}
