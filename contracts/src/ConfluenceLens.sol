// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {LegStatus, Plan} from "./ConfluenceSplitter.sol";
import {MakerVenue} from "./libraries/MakerVenue.sol";
import {PlanCheck} from "./libraries/PlanCheck.sol";
import {PoolVenue} from "./libraries/PoolVenue.sol";

/// @dev The hook's views the Lens reads (all public on `ConfluenceHook`).
interface IConfluenceHookLens {
    function poolManager() external view returns (IPoolManager);
    function splitter() external view returns (address);
    function splitterOut() external view returns (address);
    function MAX_STRATEGIES() external view returns (uint256);
    function anchorOfX(PoolId poolId) external view returns (int24 snapTick, int56 emaTickX, bool fresh);
    function strategiesOf(PoolId poolId) external view returns (MakerVenue.Entry[] memory);
}

/// @title ConfluenceLens
/// @notice The hook's decision for a swap, as a breakdown (V2-09, D-37): per slot the input, output and status the
///         swap would report, the totals, the pool-only reference, the anchor and the gain. Stateless, view, never
///         called during a swap. Anyone may call every function.
/// @dev **Same code as the hook.** The splitter is called and its plan checked by `PlanCheck`, the library the hook
///      itself runs, so a plan the hook would refuse (or cut off at `PLAN_GAS_CAP`) is quoted as pool-only by the same
///      lines. The legs come from the plan (each is filled for exactly its planned amounts or not at all, D-35); the
///      pool's share is priced here by `PoolVenue`, the exact port of v4's swap loop, never from the plan's own pool
///      numbers. No `MakerVenue` maths is copied here and no router call is made (an exclusive strategy refuses the
///      Lens as taker).
///
///      **What a view cannot see.** The Lens assumes every planned leg fills. `SKIP_REVERT` (the router refuses the leg
///      at fill time) and `SKIP_GAS` (the caller's gas limit) are execution-time outcomes: V4Quoter, which runs the
///      real hook, is the authority for them. When `poolExact` is false the pool-only part of the quote runs past the
///      walk `PoolVenue` bounds (8 ranges, 16 steps), and apps must take the total from V4Quoter. `minHookGas` is a
///      sufficient bound, not a tight one.
///
///      **Anchor.** It quotes at `anchorOfX`: the value the next swap in the SAME block sees (what the block's first
///      swap stores, or what is stored). A swap in a later block uses that block's snapshot and a decayed EMA, so band
///      caps and drift (and so skip codes) can differ from a quote taken earlier.
///
///      **Trust.** Everything is read from `key.hooks` (PoolManager, splitters, anchor, registry) and the Lens does
///      not check it is a genuine `ConfluenceHook`: quotes mean something only for one. Apps pin the hook address.
contract ConfluenceLens {
    using PoolIdLibrary for PoolKey;

    /// @notice One registry slot's part of a quoted swap. For exact input `amountIn` is the leg's input and
    ///         `amountOut` its exact output; for exact output `amountIn` is its gross input and `amountOut` the
    ///         exact output (as in `ConfluenceSwap`). `status` is the `LegStatus` code the swap's event would show.
    struct LegQuote {
        address maker;
        bytes32 strategyHash;
        uint256 amountIn;
        uint256 amountOut;
        uint8 status;
    }

    /// @notice A quote with its reasons.
    /// @param exactIn True for exact input.
    /// @param totalIn What the trader pays.
    /// @param totalOut What the trader gets.
    /// @param poolIn The input the pool's share takes.
    /// @param poolOut The output the pool's share gives.
    /// @param poolOnlyIn The input pool-only takes (all of it, or less at a hard end).
    /// @param poolOnlyOut The output pool-only gives for it.
    /// @param poolExact False only for a pool-only quote that runs past the walk: the totals are then the walked
    ///        part, and the total must come from V4Quoter. A quote with a leg is always exact.
    /// @param poolOnlyExact False when the pool-only reference runs past the walk.
    /// @param gainBps Output gained (exact input) or input saved (exact output) against pool-only, in basis points of
    ///        pool-only; a lower bound when `poolOnlyExact` is false.
    /// @param snapTick The anchor's snapshot tick.
    /// @param emaTickX The anchor's EMA, tick times 2^16.
    /// @param anchorFresh True if a swap already stored the anchor this block.
    /// @param planCode `LegStatus.FILLED` if the plan runs (or no plan was needed), `SKIP_GAS` or `SKIP_PLAN` if the
    ///        hook would go pool-only.
    /// @param minHookGas A SUFFICIENT bound (not tight) on the gas the hook needs at `beforeSwap` entry to run every
    ///        planned leg without `SKIP_GAS`; 0 if no leg is planned.
    /// @param legs One entry per registry slot the hook reads (at most `MAX_STRATEGIES`).
    struct Breakdown {
        bool exactIn;
        uint256 totalIn;
        uint256 totalOut;
        uint256 poolIn;
        uint256 poolOut;
        uint256 poolOnlyIn;
        uint256 poolOnlyOut;
        bool poolExact;
        bool poolOnlyExact;
        int256 gainBps;
        int24 snapTick;
        int56 emaTickX;
        bool anchorFresh;
        uint8 planCode;
        uint256 minHookGas;
        LegQuote[] legs;
    }

    /// @notice One direction of a maker's limits: exact input in input units, exact output in output units.
    /// @dev A status of `FILLED` means usable now; then `min` and `max` are the smallest and largest fill that pass the
    ///      guard, the wallet, the allowance and the PoolManager's balance. Otherwise they are zero and the status is
    ///      the reason.
    struct Side {
        uint8 statusIn;
        uint256 minIn;
        uint256 maxIn;
        uint8 statusOut;
        uint256 minOut;
        uint256 maxOut;
    }

    /// @notice A registered maker's limits in both directions.
    struct MakerLimit {
        address maker;
        bytes32 strategyHash;
        Side zeroForOne;
        Side oneForZero;
    }

    /// @dev Gas the hook spends outside the plan and the legs: the anchor update, registry reads, the take and the
    ///      settles, the event. Generous on purpose: `minHookGas` is a sufficient bound.
    uint256 public constant HOOK_ALLOWANCE = 150_000;
    /// @dev Gas one leg spends beyond the router call's cap: the order rebuild and hash, the approvals.
    uint256 public constant LEG_ALLOWANCE = 100_000;

    uint256 private constant _BPS = 10_000;
    // casting to 'uint256' is safe: int128 max is positive
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 private constant _MAX_INT128 = uint256(uint128(type(int128).max));

    /// @notice The quote of a swap on `key`: `amountSpecified` < 0 is exact input, > 0 exact output, as in v4. Quotes at
    ///         the same price limits V4Quoter uses (the whole price range). Anyone may call it. Never reverts for a
    ///         broken maker, a reverting or malformed splitter, or a plan the hook would refuse; it reverts for a pool
    ///         that does not exist (the hook's anchor read does). An amount of 0, or beyond int128 either way, is
    ///         quoted pool-only (the hook does not split it).
    function quote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified)
        external
        view
        returns (Breakdown memory b)
    {
        IConfluenceHookLens hook = IConfluenceHookLens(address(key.hooks));
        PoolId id = key.toId();
        IPoolManager pm = hook.poolManager();
        b.exactIn = amountSpecified < 0;
        (b.snapTick, b.emaTickX, b.anchorFresh) = hook.anchorOfX(id);
        MakerVenue.Entry[] memory slots = hook.strategiesOf(id);
        uint256 n = Math.min(slots.length, hook.MAX_STRATEGIES());
        b.legs = new LegQuote[](n);
        for (uint256 i; i < n; i++) {
            (b.legs[i].maker, b.legs[i].strategyHash) = (slots[i].maker, slots[i].strategyHash);
        }
        if (amountSpecified == 0) return b;
        // casting to 'uint256' is safe: the sign is known, and -(x + 1) + 1 does not overflow for int256 min
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount = b.exactIn ? uint256(-(amountSpecified + 1)) + 1 : uint256(amountSpecified);

        Plan memory p;
        uint256 planGas = 0;
        if (n > 0) {
            if (amount > _MAX_INT128) {
                b.planCode = LegStatus.SKIP_PLAN; // the hook does not split it: pool-only
            } else {
                uint256 g = gasleft();
                (b.planCode, p) = PlanCheck.plan(
                    b.exactIn ? hook.splitter() : hook.splitterOut(),
                    pm,
                    key,
                    zeroForOne,
                    _limit(zeroForOne),
                    amount,
                    b.snapTick,
                    b.emaTickX,
                    n,
                    b.exactIn
                );
                planGas = g - gasleft();
            }
        }
        // The hook's own rule (`_split`): a refused plan labels every slot with its code; otherwise each slot has the
        // plan's status, and a planned leg its planned amounts (it is filled for exactly those or not at all, D-35).
        uint256 legsIn = 0;
        uint256 legsOut = 0;
        uint256 count = 0;
        for (uint256 i; i < n; i++) {
            if (b.planCode != LegStatus.FILLED) {
                b.legs[i].status = b.planCode;
                continue;
            }
            // casting to 'uint8' is safe: `PlanCheck.check` bounds every status by LegStatus.MAX_CODE
            // forge-lint: disable-next-line(unsafe-typecast)
            b.legs[i].status = uint8(p.status[i]);
            if (p.amountIn[i] > 0) {
                (b.legs[i].amountIn, b.legs[i].amountOut) = (p.amountIn[i], p.amountOut[i]);
                legsIn += p.amountIn[i];
                legsOut += p.amountOut[i];
                count++;
            }
        }
        if (count > 0) {
            b.minHookGas =
                HOOK_ALLOWANCE + planGas + count * (PlanCheck.LEG_GAS_CAP + LEG_ALLOWANCE) + PlanCheck.GAS_RESERVE;
        }
        // `p` is the zeroed plan when no plan was made; `count` is then 0 and `p` is not read.
        // forge-lint: disable-next-line(uninitialized-local)
        _price(b, key, pm, zeroForOne, amount, legsIn, legsOut, count > 0 ? p.tail : 0);
    }

    /// @notice The registered makers' limits on `key`, both directions: whether each can fill now and its smallest and
    ///         largest fill (input units for exact input, output units for exact output). Anyone may call it. The
    ///         splitters report a maker's caps whatever the trade size (they are not clamped to it), so they are read
    ///         from a plan for one wei; a maker that is usable shows `FILLED` there with caps, any other shows its
    ///         reason and zero caps. A refused or failed plan labels every maker `SKIP_PLAN`.
    function makerLimits(PoolKey calldata key) external view returns (MakerLimit[] memory out) {
        IConfluenceHookLens hook = IConfluenceHookLens(address(key.hooks));
        PoolId id = key.toId();
        // forge-lint: disable-next-line(unused-return)
        (int24 snap, int56 emaX,) = hook.anchorOfX(id);
        MakerVenue.Entry[] memory slots = hook.strategiesOf(id);
        uint256 n = Math.min(slots.length, hook.MAX_STRATEGIES());
        IPoolManager pm = hook.poolManager();
        out = new MakerLimit[](n);
        for (uint256 i; i < n; i++) {
            (out[i].maker, out[i].strategyHash) = (slots[i].maker, slots[i].strategyHash);
        }
        if (n == 0) return out;
        for (uint256 d; d < 2; d++) {
            bool zfo = d == 0;
            for (uint256 m; m < 2; m++) {
                bool exactIn = m == 0;
                // Four plans in all (two modes, two directions): the loops are bounded by constants.
                // forge-lint: disable-start(calls-loop)
                (uint8 code, Plan memory p) = PlanCheck.plan(
                    exactIn ? hook.splitter() : hook.splitterOut(), pm, key, zfo, _limit(zfo), 1, snap, emaX, n, exactIn
                );
                // forge-lint: disable-end(calls-loop)
                for (uint256 i; i < n; i++) {
                    uint8 st = code;
                    uint256 lo = 0;
                    uint256 hi = 0;
                    if (code == LegStatus.FILLED) {
                        (lo, hi) = (p.capMin[i], p.capIn[i]);
                        // casting to 'uint8' is safe: `PlanCheck.check` bounds every status by LegStatus.MAX_CODE
                        // forge-lint: disable-next-line(unsafe-typecast)
                        st = hi != 0 ? LegStatus.FILLED : uint8(p.status[i]);
                    }
                    Side memory s = zfo ? out[i].zeroForOne : out[i].oneForZero;
                    if (exactIn) (s.statusIn, s.minIn, s.maxIn) = (st, lo, hi);
                    else (s.statusOut, s.minOut, s.maxOut) = (st, lo, hi);
                }
            }
        }
    }

    /// @dev Totals, the pool's share and the pool-only reference, priced by `PoolVenue` (the v4 loop port).
    function _price(
        Breakdown memory b,
        PoolKey calldata key,
        IPoolManager pm,
        bool zeroForOne,
        uint256 amount,
        uint256 legsIn,
        uint256 legsOut,
        uint256 tail
    ) private view {
        PoolVenue.Pool memory pool = PoolVenue.read(pm, key.toId(), key.tickSpacing, zeroForOne, _limit(zeroForOne));
        bool legged = legsIn > 0;
        uint256 share = 0;
        uint256 used = 0;
        uint256 got = 0;
        if (b.exactIn) {
            share = amount - legsIn;
            (got, used,) = PoolVenue.quoteExactIn(pool, share);
            (b.poolIn, b.poolOut) = (used, got);
            (b.totalIn, b.totalOut) = (legsIn + used, legsOut + got);
            (b.poolOnlyOut, b.poolOnlyIn,) = PoolVenue.quoteExactIn(pool, amount);
            b.poolExact = legged || !(pool.truncated && used < share);
            b.poolOnlyExact = !(pool.truncated && b.poolOnlyIn < amount);
        } else {
            share = amount - legsOut;
            (used, got,) = PoolVenue.quoteExactOut(pool, share);
            (b.poolIn, b.poolOut) = (used, got);
            (b.totalIn, b.totalOut) = (legsIn + used, legsOut + got);
            (b.poolOnlyIn, b.poolOnlyOut,) = PoolVenue.quoteExactOut(pool, amount);
            b.poolExact = legged || !(pool.truncated && got < share);
            b.poolOnlyExact = !(pool.truncated && b.poolOnlyOut < amount);
        }
        // Gain against pool-only. When a split's pool-only run ends past the walk the reference is the walked part plus
        // the plan's own upper bound on the rest (exact input only: exact output needs the walk to cover all of B), so
        // the gain is then a lower bound.
        if (b.exactIn) {
            uint256 ref = b.poolOnlyOut + (legged && !b.poolOnlyExact ? tail : 0);
            // casting to 'int256' is safe: every amount here is below 2^255 (the hook caps them at int128)
            // forge-lint: disable-next-line(unsafe-typecast)
            if (ref != 0) b.gainBps = (int256(b.totalOut) - int256(ref)) * int256(_BPS) / int256(ref);
        } else if (b.poolOnlyIn != 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            b.gainBps = (int256(b.poolOnlyIn) - int256(b.totalIn)) * int256(_BPS) / int256(b.poolOnlyIn);
        }
    }

    /// @dev The price limit V4Quoter swaps with: the whole range (`BaseV4Quoter.sol:48`).
    function _limit(bool zeroForOne) private pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }
}
