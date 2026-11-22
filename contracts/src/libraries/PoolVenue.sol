// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {SplitMath} from "./SplitMath.sol";

/// @title PoolVenue
/// @notice Reads a live v4 pool into tick-range segments the solver can use (V2-02, ARCHITECTURE-v2 sections 2 and 3).
///         View only: no state writes. Never reverts on any pool state or limit (a limit v4 would reject, an
///         uninitialised pool or a 100% fee give an empty list).
/// @dev Step-exact (D-30): the walk mirrors `Pool.swap`'s loop (v4-core `Pool.sol:344-436`). v4 steps to the next
///      initialised tick or to the edge of the 256-tick bitmap word, whichever is nearer, and rounds each step on
///      its own; one segment is one such step with liquidity and width. So a word edge splits a liquidity range in
///      two (same liquidity, same curve), and a quote built from the segments equals the chain to the wei. Steps
///      without liquidity (a gap) or width (the price exactly on a tick) make no segment but still apply the
///      tick's liquidityNet.
///
///      Bounds: at most `MAX_TICK_RANGES` segments and `MAX_TICK_STEPS` steps (bitmap words read), empty ones
///      included. The walk also stops at the trader's `sqrtPriceLimitX96`. `truncated` is true when it stopped at a
///      bound with liquidity left before the limit: the last segment is then not a real end, and `venues` leaves it
///      uncapped ("the pool takes the rest"). Otherwise every cap is hard.
///
///      Fee: v4's combined swap fee for the swap's direction, as `Pool.swap` charges it (`Pool.sol:286-308`). It is
///      read from slot0, so it assumes the hook returns no LP-fee override from `beforeSwap` (CLAUDE.md hard rule).
library PoolVenue {
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint24;

    /// @notice Most segments one read returns (ARCHITECTURE-v2 section 5; V2-11 fixes it). Same number as the
    ///         piecewise solver's bound.
    uint256 internal constant MAX_TICK_RANGES = SplitMath.MAX_SEGMENTS;

    /// @notice Most swap-loop steps one read walks, including steps that make no segment (D-30; V2-11 fixes it).
    uint256 internal constant MAX_TICK_STEPS = 16;

    /// @dev v4's fee scale and its ceiling (SwapMath.MAX_SWAP_FEE = 1e6 pips = 100%).
    uint256 private constant MAX_SWAP_FEE = 1e6;

    /// @dev pips (1e6 = 100%) to SplitMath's fee scale (1e9 = 100%).
    uint32 private constant PIPS_TO_E9 = 1000;

    /// @notice One step of the swap loop as a constant-product venue in the swap's direction.
    /// @param sqrtPriceStartX96 Where the step starts.
    /// @param sqrtPriceEndX96 Where it ends: an initialised tick, a bitmap word edge or the trader's limit.
    /// @param liquidity Active liquidity during the step.
    /// @param x Input-token virtual reserve at the start price, floored (zero for one: L * 2^96 / sqrtP).
    /// @param y Output-token virtual reserve at the start price, floored (zero for one: L * sqrtP / 2^96).
    /// @param capIn Gross input, fee included, that moves the price to the end (the least input that does).
    /// @param capOut Output received at the end. Exact output of `capOut` costs exactly `capIn`.
    struct Segment {
        uint160 sqrtPriceStartX96;
        uint160 sqrtPriceEndX96;
        uint128 liquidity;
        uint256 x;
        uint256 y;
        uint256 capIn;
        uint256 capOut;
    }

    /// @notice The pool in one direction.
    /// @param zeroForOne The direction read.
    /// @param swapFee v4's combined swap fee for that direction, in pips.
    /// @param truncated The walk stopped at a bound with liquidity left: the last segment is not a hard end.
    /// @param segments In walk order, current range first; at most `MAX_TICK_RANGES`.
    struct Pool {
        bool zeroForOne;
        uint24 swapFee;
        bool truncated;
        Segment[] segments;
    }

    /// @notice The pool's segments in the swap's direction, ending at `sqrtPriceLimitX96`.
    /// @param manager The PoolManager.
    /// @param id The pool.
    /// @param tickSpacing The pool's tick spacing (from its key).
    /// @param zeroForOne Swap direction.
    /// @param sqrtPriceLimitX96 The trader's price limit, as in `SwapParams`.
    function read(IPoolManager manager, PoolId id, int24 tickSpacing, bool zeroForOne, uint160 sqrtPriceLimitX96)
        internal
        view
        returns (Pool memory p)
    {
        p.zeroForOne = zeroForOne;
        (uint160 sqrtP, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(id);
        if (sqrtP == 0) return p; // not initialised

        uint16 pf = zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
        uint24 swapFee = pf == 0 ? lpFee : ProtocolFeeLibrary.calculateSwapFee(pf, lpFee);
        p.swapFee = swapFee;
        if (swapFee >= MAX_SWAP_FEE) return p; // the pool gives nothing (exact output reverts in v4)
        if (!_limitValid(sqrtP, sqrtPriceLimitX96, zeroForOne)) return p; // v4 would revert

        Walk memory w = Walk({
            manager: manager,
            id: id,
            tickSpacing: tickSpacing,
            zeroForOne: zeroForOne,
            limit: sqrtPriceLimitX96,
            swapFee: swapFee,
            sqrtP: sqrtP,
            tick: tick,
            liq: manager.getLiquidity(id),
            count: 0
        });
        Segment[] memory buf = new Segment[](MAX_TICK_RANGES);
        for (uint256 step; step < MAX_TICK_STEPS && w.count < MAX_TICK_RANGES && w.sqrtP != w.limit; step++) {
            _step(w, buf);
        }
        p.truncated = w.sqrtP != w.limit && w.liq > 0;
        uint256 count = w.count;
        assembly ("memory-safe") {
            mstore(buf, count) // shrink to the segments found (count <= MAX_TICK_RANGES)
        }
        p.segments = buf;
    }

    /// @notice One step as a venue: virtual reserves at the start, and the amounts that reach the end.
    /// @dev Amounts are v4's: input `getAmount{0,1}Delta(..., true)` grossed up by the fee, rounded up, which equals
    ///      `SwapMath.computeSwapStep`'s amountIn + feeAmount at the target (SwapMath.sol:66-74); output
    ///      `getAmount{1,0}Delta(..., false)` (:84-86). Bounds for L < 2^128 and sqrtP in v4's range: the input
    ///      delta < 2^224, so `capIn` < 2^244; `x`, `y` < 2^192. Needs `swapFee < 1e6`.
    function segment(uint160 start, uint160 end, uint128 liquidity, uint24 swapFee, bool zeroForOne)
        internal
        pure
        returns (Segment memory s)
    {
        s.sqrtPriceStartX96 = start;
        s.sqrtPriceEndX96 = end;
        s.liquidity = liquidity;
        uint256 netIn;
        if (zeroForOne) {
            netIn = SqrtPriceMath.getAmount0Delta(end, start, liquidity, true);
            s.capOut = SqrtPriceMath.getAmount1Delta(end, start, liquidity, false);
            s.x = FullMath.mulDiv(liquidity, FixedPoint96.Q96, start);
            s.y = FullMath.mulDiv(liquidity, start, FixedPoint96.Q96);
        } else {
            netIn = SqrtPriceMath.getAmount1Delta(start, end, liquidity, true);
            s.capOut = SqrtPriceMath.getAmount0Delta(start, end, liquidity, false);
            s.x = FullMath.mulDiv(liquidity, start, FixedPoint96.Q96);
            s.y = FullMath.mulDiv(liquidity, FixedPoint96.Q96, start);
        }
        s.capIn = FullMath.mulDivRoundingUp(netIn, MAX_SWAP_FEE, MAX_SWAP_FEE - swapFee);
    }

    /// @notice `TickBitmap.nextInitializedTickWithinOneWord` on a given word (TickBitmap.sol:85-121). v4's function
    ///         reads the PoolManager's own storage mapping, so a library outside it cannot call it (D-30). `word` must
    ///         be the bitmap word at the position v4 reads: `position(compress(tick))` when `lte`, else
    ///         `position(compress(tick) + 1)`. Same unchecked arithmetic as v4.
    function nextInWord(uint256 word, int24 tick, int24 tickSpacing, bool lte)
        internal
        pure
        returns (int24 next, bool initialized)
    {
        unchecked {
            int24 compressed = TickBitmap.compress(tick, tickSpacing);
            if (lte) {
                (, uint8 bitPos) = TickBitmap.position(compressed);
                uint256 masked = word & (type(uint256).max >> (uint256(type(uint8).max) - bitPos));
                initialized = masked != 0;
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {
                (, uint8 bitPos) = TickBitmap.position(++compressed);
                uint256 masked = word & ~((1 << bitPos) - 1);
                initialized = masked != 0;
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }
        }
    }

    /// @notice The segments as SplitMath venues for one mode. Each cap is the amount that reaches the segment's end
    ///         (`capIn` for exact input, `capOut` for exact output); the last is uncapped when the read was truncated.
    function venues(Pool memory p, bool exactIn) internal pure returns (SplitMath.Venue[] memory v) {
        uint256 n = p.segments.length;
        v = new SplitMath.Venue[](n);
        uint32 feeE9 = uint32(p.swapFee) * PIPS_TO_E9;
        for (uint256 i; i < n && i < MAX_TICK_RANGES; i++) {
            Segment memory s = p.segments[i];
            v[i] = SplitMath.Venue(s.x, s.y, feeE9, exactIn ? s.capIn : s.capOut);
        }
        if (p.truncated && n > 0) v[n - 1].cap = type(uint256).max;
    }

    /// @notice The pool-only output for `amountIn`, as v4 computes it, over the walked segments.
    /// @return amountOut Output.
    /// @return amountInUsed Input taken: less than `amountIn` only when the walked segments run out (the real swap
    ///         goes on past a truncated walk, or stops at the limit).
    /// @return touched Segments that took input.
    function quoteExactIn(Pool memory p, uint256 amountIn)
        internal
        pure
        returns (uint256 amountOut, uint256 amountInUsed, uint256 touched)
    {
        uint256 remaining = _clamp(amountIn);
        for (uint256 i; i < p.segments.length && i < MAX_TICK_RANGES && remaining > 0; i++) {
            Segment memory s = p.segments[i];
            touched++;
            if (remaining >= s.capIn) {
                amountOut += s.capOut;
                amountInUsed += s.capIn;
                remaining -= s.capIn;
            } else {
                (, uint256 stepIn, uint256 stepOut, uint256 feeAmount) = SwapMath.computeSwapStep(
                    s.sqrtPriceStartX96, s.sqrtPriceEndX96, s.liquidity, -int256(remaining), p.swapFee
                );
                amountOut += stepOut;
                amountInUsed += stepIn + feeAmount; // = remaining: the step ends inside the segment
                remaining = 0;
            }
        }
    }

    /// @notice The pool-only input for `amountOut`, as v4 computes it, over the walked segments.
    /// @return amountIn Input, fee included.
    /// @return amountOutGiven Output: less than `amountOut` only when the walked segments run out.
    /// @return touched Segments that gave output.
    function quoteExactOut(Pool memory p, uint256 amountOut)
        internal
        pure
        returns (uint256 amountIn, uint256 amountOutGiven, uint256 touched)
    {
        uint256 remaining = _clamp(amountOut);
        for (uint256 i; i < p.segments.length && i < MAX_TICK_RANGES && remaining > 0; i++) {
            Segment memory s = p.segments[i];
            touched++;
            if (remaining >= s.capOut) {
                amountIn += s.capIn;
                amountOutGiven += s.capOut;
                remaining -= s.capOut;
            } else {
                (, uint256 stepIn, uint256 stepOut, uint256 feeAmount) = SwapMath.computeSwapStep(
                    s.sqrtPriceStartX96, s.sqrtPriceEndX96, s.liquidity, int256(remaining), p.swapFee
                );
                amountIn += stepIn + feeAmount;
                amountOutGiven += stepOut;
                remaining = 0;
            }
        }
    }

    // ------------------------------------------------------------------------------------------------ private

    /// @dev The walk's state, in memory to keep `read` within the stack (via_ir).
    struct Walk {
        IPoolManager manager;
        PoolId id;
        int24 tickSpacing;
        bool zeroForOne;
        uint160 limit;
        uint24 swapFee;
        uint160 sqrtP;
        int24 tick;
        uint128 liq;
        uint256 count;
    }

    /// @dev One iteration of `Pool.swap`'s loop (Pool.sol:344-436) taken all the way to its target: to the next
    ///      initialised tick or word edge (clamped to MIN/MAX_TICK, :351-356), or to the limit. A step with
    ///      liquidity and width becomes a segment; reaching the tick crosses it (liquidityNet with the opposite sign
    ///      leftward, :424; never type(int128).min) and moves the tick as v4 does (:431).
    function _step(Walk memory w, Segment[] memory buf) private view {
        (int24 tickNext, bool initialized) = _nextTick(w.manager, w.id, w.tick, w.tickSpacing, w.zeroForOne);
        if (tickNext <= TickMath.MIN_TICK) tickNext = TickMath.MIN_TICK;
        if (tickNext >= TickMath.MAX_TICK) tickNext = TickMath.MAX_TICK;
        uint160 sqrtNext = TickMath.getSqrtPriceAtTick(tickNext);
        uint160 target = SwapMath.getSqrtPriceTarget(w.zeroForOne, sqrtNext, w.limit);

        if (w.liq > 0 && target != w.sqrtP) {
            buf[w.count] = segment(w.sqrtP, target, w.liq, w.swapFee, w.zeroForOne);
            w.count++;
        }
        w.sqrtP = target;
        if (target == sqrtNext) {
            if (initialized) {
                (, int128 net) = w.manager.getTickLiquidity(w.id, tickNext);
                w.liq = LiquidityMath.addDelta(w.liq, w.zeroForOne ? -net : net);
            }
            w.tick = w.zeroForOne ? tickNext - 1 : tickNext;
        }
        // else the step ended at the limit, and `read` stops.
    }

    /// @dev The word `nextInWord` needs, read from the PoolManager (StateLibrary.getTickBitmap takes the word
    ///      position, StateLibrary.sol:201-213).
    function _nextTick(IPoolManager manager, PoolId id, int24 tick, int24 tickSpacing, bool lte)
        private
        view
        returns (int24, bool)
    {
        int24 compressed = TickBitmap.compress(tick, tickSpacing);
        unchecked {
            (int16 wordPos,) = TickBitmap.position(lte ? compressed : compressed + 1);
            return nextInWord(manager.getTickBitmap(id, wordPos), tick, tickSpacing, lte);
        }
    }

    /// @dev Pool.swap's limit checks (Pool.sol:322-338), as a bool instead of a revert.
    function _limitValid(uint160 sqrtP, uint160 limit, bool zeroForOne) private pure returns (bool) {
        return zeroForOne
            ? limit < sqrtP && limit > TickMath.MIN_SQRT_PRICE
            : limit > sqrtP && limit < TickMath.MAX_SQRT_PRICE;
    }

    /// @dev Amounts are passed to v4 as int256; anything larger is clamped (no pool holds 2^255 of a token).
    function _clamp(uint256 amount) private pure returns (uint256) {
        return amount > uint256(type(int256).max) ? uint256(type(int256).max) : amount;
    }
}
