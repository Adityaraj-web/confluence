// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {MockMUMB} from "../../src/mocks/MockMUMB.sol";
import {PoolVenue} from "../../src/libraries/PoolVenue.sol";
import {SplitMath} from "../../src/libraries/SplitMath.sol";
import {PoolBase} from "../base/PoolBase.t.sol";
import {SplitHelpers} from "../base/SplitHelpers.sol";
import {Vectors} from "../base/Vectors.sol";

/// @notice V2-02 acceptance on the fork: PoolVenue's segments and quotes against real v4 swaps, and the piecewise
///         split against the V2-00 vectors.
/// @dev Pools: the v1 demo pool from `PoolBase` (one range, a bitmap word edge at tick 276420 going MUMB to USDC) and
///      hookless pools built here from fresh 18-decimal tokens at price 1 (tick 0). Every real swap runs from one
///      `vm.snapshotState()` and is reverted. Choices are in D-30.
contract V202PoolVenueTest is PoolBase, SplitHelpers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant NONE = type(uint256).max;

    struct Pos {
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }

    struct Real {
        uint256 amountIn;
        uint256 amountOut;
        uint160 sqrtPriceAfter;
        int24 tickAfter;
    }

    // =====================================================================================================
    // Acceptance
    // =====================================================================================================

    /// @dev v1 pool, one range: 1,000 USDC to MUMB (the vector's pool-only number) and 100 MUMB to USDC (before the
    ///      word edge at 276420). The USDC-to-MUMB segment is the vector's `poolVenue`, the venue gate M3 uses.
    function test_V202_singleRangeMatchesSwap() public {
        Vectors.V1Case memory c = Vectors.v1Case(Vectors.read(Vectors.V1_DEMO), 0);
        bool zfo = usdcForMumb();
        assertEq(zfo, c.pool.zeroForOne, "vector direction");

        PoolVenue.Pool memory p = _read(key, zfo, _lim(zfo));
        assertGt(p.segments.length, 0, "segments");
        assertEq(p.segments[0].x, c.poolVenue.x, "segment 0 x = vector poolVenue");
        assertEq(p.segments[0].y, c.poolVenue.y, "segment 0 y = vector poolVenue");
        assertEq(uint256(p.swapFee) * 1000, uint256(c.poolVenue.feeE9), "fee = vector poolVenue");
        assertEq(p.segments[0].capIn, c.poolCapIn, "segment 0 capIn = vector poolVenue");

        _assertSingleRange(key, zfo, 1_000e6, "USDC to MUMB");
        assertEq(_realise(key, zfo, -int256(1_000e6), _lim(zfo)).amountOut, c.poolOnlyOut, "pool-only vs vector");
        _assertSingleRange(key, !zfo, 100e18, "MUMB to USDC");
    }

    /// @dev Three overlapping positions: A [-600, 600], B [-300, -60], C [-480, -180], price at tick 0. Zero for one
    ///      crosses -60 (+B), -180 (+C) and -300 (-B) and ends inside [-480, -300]. The walk also passes the bitmap word
    ///      edge at tick 0 (a zero-width step: no segment).
    function test_V202_crossesTicks() public {
        PoolKey memory k = _overlapPool();
        PoolVenue.Pool memory p = _read(k, true, _lim(true));
        assertGe(p.segments.length, 5, "segments");
        assertEq(
            p.segments[0].sqrtPriceStartX96, uint160(FixedPoint96.Q96), "starts at the price (tick 0 edge skipped)"
        );
        _assertEnds(p, 0, -60);
        _assertEnds(p, 1, -180);
        _assertEnds(p, 2, -300);
        _assertEnds(p, 3, -480);
        assertEq(p.segments[0].liquidity, 1e22, "A");
        assertEq(p.segments[1].liquidity, 3e22, "A + B");
        assertEq(p.segments[2].liquidity, 6e22, "A + B + C");
        assertEq(p.segments[3].liquidity, 4e22, "A + C");

        uint256 amount = p.segments[0].capIn + p.segments[1].capIn + p.segments[2].capIn + p.segments[3].capIn / 2;
        (uint256 q, uint256 used, uint256 touched) = PoolVenue.quoteExactIn(p, amount);
        Real memory r = _realise(k, true, -int256(amount), _lim(true));
        assertEq(r.amountIn, amount, "real swap took the whole input");
        assertGe(r.tickAfter, -480, "ends above -480");
        assertLt(r.tickAfter, -300, "crossed -60, -180 and -300");
        assertEq(used, amount, "quote used the whole input");
        assertEq(touched, 4, "quote touched 4 segments");
        assertApproxEqAbs(q, r.amountOut, 2 * 3, "within 2 wei per crossing");
        console2.log("crossesTicks deviation (wei)", _absDiff(q, r.amountOut));
    }

    /// @dev Vector pool, both directions: a limit inside a range and a limit on an initialised tick. The list ends at
    ///      the limit with a hard cap, and a real swap with that limit stops there having paid and received the sums.
    function test_V202_respectsPriceLimit() public {
        PoolKey memory k = _crossingPool();
        _assertLimit(k, true, TickMath.getSqrtPriceAtTick(-150), 3);
        _assertLimit(k, false, TickMath.getSqrtPriceAtTick(150), 3);
        _assertLimit(k, true, TickMath.getSqrtPriceAtTick(-120), 2);
        _assertLimit(k, false, TickMath.getSqrtPriceAtTick(120), 2);
    }

    /// @dev Ten initialised ticks in the zero-for-one path (positions [-60 i, 1200], i = 1..10). The walk returns 8
    ///      segments and is truncated, so the last venue is uncapped. A trade past the 8 ranges with one capped maker:
    ///      the allocation sums, the maker stays within its cap, the pool ends in the last walked segment, and the
    ///      real swap of the pool's share does not revert and takes all of it.
    function test_V202_walkLimitFallback() public {
        PoolKey memory k = _tenTickPool();
        PoolVenue.Pool memory p = _read(k, true, _lim(true));
        assertEq(p.segments.length, PoolVenue.MAX_TICK_RANGES, "8 segments");
        assertTrue(p.truncated, "truncated");
        _assertEnds(p, 7, -480);
        SplitMath.Venue[] memory pv = PoolVenue.venues(p, true);
        assertEq(pv[7].cap, NONE, "last venue uncapped");
        assertEq(pv[6].cap, p.segments[6].capIn, "earlier venues capped");

        uint256 walked;
        for (uint256 i; i < 8; i++) {
            walked += p.segments[i].capIn;
        }
        uint256 ninth =
            PoolVenue.segment(
            TickMath.getSqrtPriceAtTick(-480), TickMath.getSqrtPriceAtTick(-540), 2e21, p.swapFee, true
        )
        .capIn;
        SplitMath.Venue[] memory makers = new SplitMath.Venue[](1);
        makers[0] = SplitMath.Venue(1e22, 1e22, 3_000_000, ninth / 4);
        uint256 amount = walked + ninth / 2;

        (uint256[] memory a, uint256 crossed) = SplitMath.solveExactIn(pv, makers, amount);
        assertEq(a.length, 2, "length");
        assertEq(a[0] + a[1], amount, "sum");
        assertLe(a[1], makers[0].cap, "maker within its cap");
        assertGt(a[0], walked, "the pool's share goes past the 8 walked ranges");
        assertEq(crossed, 7, "the pool ends in the last (uncapped) segment");

        Real memory r = _realise(k, true, -int256(a[0]), _lim(true));
        assertEq(r.amountIn, a[0], "the real swap takes the pool's whole share");
        assertGt(r.amountOut, 0, "output");
    }

    /// @dev The vector pool built on chain; for all 8 cases: segments equal the vector's in every field, the maker's
    ///      share within amount/1e9, ranges crossed equal, the real pool leg equals the quote, totals within 1e-9.
    function test_V202_splitWithCrossingMatchesVectors() public {
        PoolKey memory k = _crossingPool();
        string memory json = Vectors.read(Vectors.POOL_CROSSING);
        uint256 n = Vectors.count(json);
        assertEq(n, 8, "vector cases");
        for (uint256 i; i < n; i++) {
            Vectors.Crossing memory c = Vectors.crossing(json, i);
            if (i == 0) _assertPoolMatchesVector(k, c.pool);
            _checkCrossingCase(k, c);
        }
    }

    // =====================================================================================================
    // Extra
    // =====================================================================================================

    /// @dev v1 pool, MUMB to USDC, 1,000 and 777 MUMB: segment 0 ends at the bitmap word edge (tick 276420, compressed
    ///      4607 = 17 * 256 + 255) with the same liquidity on both sides. The quote, the chain and the Python model's
    ///      exact walk agree to the wei and in step count; the split with Priya matches the vector's closed form.
    function test_V202_wordEdgeMatchesSwap() public {
        string memory json = Vectors.read(Vectors.V1_DEMO);
        bool zfo = !usdcForMumb();
        PoolVenue.Pool memory p = _read(key, zfo, _lim(zfo));
        assertGe(p.segments.length, 2, "segments");
        assertEq(int256(276420 / TICK_SPACING) % 256, 255, "276420 is the last tick of its bitmap word");
        _assertEnds(p, 0, 276420);
        assertEq(p.segments[1].liquidity, p.segments[0].liquidity, "same liquidity across the word edge");
        assertEq(p.segments[1].sqrtPriceStartX96, p.segments[0].sqrtPriceEndX96, "contiguous");
        // After the edge the search reads the next word (compressed + 1): segment 1 ends at the position's upper tick,
        // and a trade past the whole range is quoted exactly (mutation M1, D-30).
        _assertEnds(p, 1, tickUpper);
        assertEq(p.segments.length, 2, "nothing past the upper tick");
        (uint256 qPast, uint256 usedPast,) = PoolVenue.quoteExactIn(p, 3_000e18);
        Real memory past = _realise(key, zfo, -int256(3_000e18), _lim(zfo));
        assertLt(past.amountIn, 3_000e18, "3,000 MUMB is past the range");
        assertEq(usedPast, past.amountIn, "past the range: input used = chain");
        assertEq(qPast, past.amountOut, "past the range: quote = chain");

        for (uint256 i = 2; i < 4; i++) {
            Vectors.V1Case memory c = Vectors.v1Case(json, i);
            assertEq(c.pool.zeroForOne, zfo, "vector direction");
            (uint256 q, uint256 used, uint256 touched) = PoolVenue.quoteExactIn(p, c.amount);
            Real memory r = _realise(key, zfo, -int256(c.amount), _lim(zfo));
            assertEq(used, c.amount, string.concat(c.name, ": used"));
            assertEq(q, r.amountOut, string.concat(c.name, ": quote = chain"));
            assertEq(q, c.poolOnlyOut, string.concat(c.name, ": quote = Python exact walk"));
            uint256 steps = vm.parseJsonUint(json, string.concat(".cases[", vm.toString(i), "].poolOnlySteps"));
            assertEq(touched, steps, string.concat(c.name, ": steps = Python exact walk"));

            SplitMath.Venue[] memory makers = new SplitMath.Venue[](1);
            makers[0] = _venueV(c.priya);
            (uint256[] memory a,) = SplitMath.solveExactIn(PoolVenue.venues(p, true), makers, c.amount);
            assertEq(a[0] + a[1], c.amount, string.concat(c.name, ": sum"));
            assertApproxEqAbs(a[1], c.allocPriya, c.amount / E9, string.concat(c.name, ": Priya's share"));
            console2.log(c.name, "Priya", a[1]);
            console2.log("  vector", c.allocPriya);
        }
    }

    /// @dev The step-exact claim (D-30): quotes equal the chain to the wei, both modes, both directions, one range and
    ///      several.
    function test_V202_quoteIsExact() public {
        bool u = usdcForMumb();
        uint256[4] memory usdcIn = [uint256(1), 1e6, 1_000e6, 2_000e6];
        uint256[3] memory mumbIn = [uint256(1e18), 777e18, 1_000e18];
        for (uint256 i; i < 4; i++) {
            _assertExactIn(key, u, usdcIn[i]);
        }
        for (uint256 i; i < 3; i++) {
            _assertExactIn(key, !u, mumbIn[i]);
        }
        _assertExactOut(key, u, 1e18);
        _assertExactOut(key, u, 500e18);
        _assertExactOut(key, !u, 1e6);
        _assertExactOut(key, !u, 500e6);

        PoolKey memory k = _crossingPool();
        uint256[3] memory amts = [uint256(1e19), 2e20, 29e19];
        for (uint256 d; d < 2; d++) {
            for (uint256 i; i < 3; i++) {
                _assertExactIn(k, d == 0, amts[i]);
                _assertExactOut(k, d == 0, amts[i]);
            }
        }
    }

    /// @dev Protocol fee on (0.1% zero for one, 0.05% one for zero): the fee is `calculateSwapFee` of the direction's
    ///      protocol fee and the LP fee, and quotes still equal the chain.
    function test_V202_protocolFeeMatchesSwap() public {
        PoolKey memory k = _crossingPool();
        vm.prank(manager.protocolFeeController());
        manager.setProtocolFee(k, uint24(1000) | (uint24(500) << 12));

        PoolVenue.Pool memory pz = _read(k, true, _lim(true));
        PoolVenue.Pool memory po = _read(k, false, _lim(false));
        assertEq(pz.swapFee, ProtocolFeeLibrary.calculateSwapFee(1000, POOL_FEE), "zero for one fee");
        assertEq(po.swapFee, ProtocolFeeLibrary.calculateSwapFee(500, POOL_FEE), "one for zero fee");
        assertTrue(pz.swapFee != po.swapFee, "the directions differ");
        for (uint256 d; d < 2; d++) {
            _assertExactIn(k, d == 0, 2e20);
            _assertExactOut(k, d == 0, 2e20);
        }
    }

    /// @dev D-29 carry-over, on the fork: an exact output the pool's walked ranges cannot give, with a capped maker.
    ///      A hard end exists only at the trader's limit (D-30): here the limit sits at the end of the liquidity
    ///      (tick -180). No revert; the pool is past every walked range (`crossed == length`), and its quote cannot fill
    ///      its share: the V2-07 hook must not rely on the prediction there (PROGRESS carry-over (a)). Without that
    ///      limit the walk cannot tell the end of the liquidity from a gap, so it is truncated and the pool takes the
    ///      rest.
    function test_V202_noNextRangeOnFork() public {
        PoolKey memory k = _crossingPool();
        PoolVenue.Pool memory open = _read(k, true, _lim(true));
        assertTrue(open.truncated, "far limit: the end of the liquidity looks like a gap, so truncated");
        assertEq(PoolVenue.venues(open, false)[open.segments.length - 1].cap, NONE, "far limit: last venue uncapped");

        PoolVenue.Pool memory p = _read(k, true, TickMath.getSqrtPriceAtTick(-180));
        assertFalse(p.truncated, "limit at the end: hard cap");
        assertEq(p.segments.length, 3, "three ranges");
        SplitMath.Venue[] memory makers = new SplitMath.Venue[](1);
        makers[0] = SplitMath.Venue(2e22, 2e22, 3_000_000, 1e20);
        uint256 amount = 5e20; // the pool's capacity is about 2.99e20 out
        (uint256[] memory b, uint256 crossed) = SplitMath.solveExactOut(PoolVenue.venues(p, false), makers, amount);
        assertEq(b[0] + b[1], amount, "sum");
        assertEq(b[1], makers[0].cap, "maker pinned at its cap");
        assertEq(crossed, 3, "past every walked range");
        (, uint256 given,) = PoolVenue.quoteExactOut(p, b[0]);
        assertLt(given, b[0], "the pool cannot give its predicted share");
    }

    /// @dev Spec review (D-30): the walk stops at `MAX_TICK_RANGES` exactly where the liquidity drops to zero, with a
    ///      one-spacing gap and deep liquidity after it. The walk cannot tell the gap from the end, so it is truncated
    ///      and the pool takes the rest. A hard cap there would push the rest onto a thin maker, worse than pool-only.
    ///      The split (real pool leg plus the maker's SwapVM output) is no worse than the real pool-only swap.
    function test_V202_gapAfterWalkIsTruncated() public {
        PoolKey memory k = _gapPool();
        PoolVenue.Pool memory p = _read(k, true, _lim(true));
        assertEq(p.segments.length, PoolVenue.MAX_TICK_RANGES, "8 segments");
        _assertEnds(p, 7, -480);
        assertTrue(p.truncated, "stopped at a bound before the limit: truncated");
        SplitMath.Venue[] memory pv = PoolVenue.venues(p, true);
        assertEq(pv[7].cap, NONE, "last venue uncapped");

        uint256 walked;
        for (uint256 i; i < 8; i++) {
            walked += p.segments[i].capIn;
        }
        uint256 amount = walked + 1e20;
        SplitMath.Venue[] memory makers = new SplitMath.Venue[](1);
        makers[0] = SplitMath.Venue(5e20, 4.8e20, 3_000_000, NONE); // thin, priced near tick -408
        (uint256[] memory a,) = SplitMath.solveExactIn(pv, makers, amount);
        assertEq(a[0] + a[1], amount, "sum");
        assertGt(a[0], walked, "the pool's share goes past the gap");

        Real memory poolOnly = _realise(k, true, -int256(amount), _lim(true));
        Real memory leg = _realise(k, true, -int256(a[0]), _lim(true));
        assertEq(poolOnly.amountIn, amount, "pool-only fills the whole input");
        assertEq(leg.amountIn, a[0], "the pool leg fills its share");
        uint256 split = leg.amountOut + (a[1] > 0 ? _cpOutInt(makers[0], a[1]) : 0);
        assertGe(split, poolOnly.amountOut, "the split is no worse than pool-only");
        console2.log("gap: pool-only out", poolOnly.amountOut);
        console2.log("gap: split out", split);
        console2.log("gap: maker share", a[1]);
    }

    /// @dev Read-only: the walk writes nothing to the PoolManager.
    function test_V202_readWritesNothing() public {
        PoolKey memory k = _overlapPool();
        vm.record();
        PoolVenue.Pool memory p = _read(k, true, _lim(true));
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(manager));
        assertGt(p.segments.length, 0, "segments");
        assertGt(reads.length, 0, "the walk reads the PoolManager");
        assertEq(writes.length, 0, "the walk writes nothing");
    }

    /// @dev Limits v4 would reject, an uninitialised pool and a 100% fee pool give an empty list, never a revert.
    function test_V202_invalidInputsAreEmpty() public {
        (uint160 sqrtP,,,) = manager.getSlot0(poolId);
        assertEq(_read(key, true, sqrtP).segments.length, 0, "zero for one, limit at the price");
        assertEq(_read(key, true, TickMath.MIN_SQRT_PRICE).segments.length, 0, "zero for one, limit at MIN");
        assertEq(_read(key, false, sqrtP).segments.length, 0, "one for zero, limit at the price");
        assertEq(_read(key, false, TickMath.MAX_SQRT_PRICE).segments.length, 0, "one for zero, limit at MAX");

        PoolKey memory none = key;
        none.fee = 500;
        assertEq(_read(none, true, _lim(true)).segments.length, 0, "uninitialised pool");

        Pos[] memory pos = new Pos[](1);
        pos[0] = Pos(-600, 600, 1e22);
        PoolKey memory full = _newPool(pos, 1_000_000);
        PoolVenue.Pool memory p = _read(full, true, _lim(true));
        assertEq(p.swapFee, 1_000_000, "100% fee read");
        assertEq(p.segments.length, 0, "100% fee pool is unusable");
        (uint256 q, uint256 used, uint256 touched) = PoolVenue.quoteExactIn(p, 1e18);
        assertEq(q + used + touched, 0, "empty quote");

        // Makers alone when the pool has no segments: index 0 takes only the remainder.
        SplitMath.Venue[] memory makers = new SplitMath.Venue[](1);
        makers[0] = SplitMath.Venue(1e22, 1e22, 3_000_000, NONE);
        (uint256[] memory a, uint256 crossed) = SplitMath.solveExactIn(PoolVenue.venues(p, true), makers, 1e18);
        assertEq(a[1], 1e18, "the maker takes everything");
        assertEq(a[0], 0, "the empty pool gets nothing");
        assertEq(crossed, 0, "crossed");
    }

    /// @dev Gas, logged only (V2-11 sets budgets): an 8-segment walk, and piecewise solves over it.
    function test_V202_gasLog() public {
        PoolKey memory k = _tenTickPool();
        PoolId id = k.toId();
        uint256 g = gasleft();
        PoolVenue.Pool memory p = PoolVenue.read(manager, id, k.tickSpacing, true, _lim(true));
        uint256 gasRead = g - gasleft();
        assertEq(p.segments.length, 8, "8 segments");
        SplitMath.Venue[] memory pv = PoolVenue.venues(p, true);
        uint256 amount;
        for (uint256 i; i < 8; i++) {
            amount += p.segments[i].capIn;
        }
        // Makers priced about 4% below the pool's start, so the pool's share crosses most of the 8 segments.
        SplitMath.Venue[] memory one = new SplitMath.Venue[](1);
        one[0] = SplitMath.Venue(1e22, 0.96e22, 3_000_000, NONE);
        g = gasleft();
        (, uint256 crossedOne) = SplitMath.solveExactIn(pv, one, amount);
        uint256 gasOne = g - gasleft();

        SplitMath.Venue[] memory three = new SplitMath.Venue[](3);
        three[0] = SplitMath.Venue(1e22, 0.96e22, 3_000_000, NONE);
        three[1] = SplitMath.Venue(8e21, 7.7e21, 500_000, NONE);
        three[2] = SplitMath.Venue(5e21, 4.81e21, 1_000_000, NONE);
        g = gasleft();
        (, uint256 crossedThree) = SplitMath.solveExactIn(pv, three, amount);
        uint256 gasThree = g - gasleft();
        assertGe(crossedOne, 5, "the measured solves cross several segments");

        console2.log("gas PoolVenue.read, 8 segments (9 steps)", gasRead);
        console2.log("gas piecewise exact in, 1 maker", gasOne);
        console2.log("  segments crossed", crossedOne);
        console2.log("gas piecewise exact in, 3 makers", gasThree);
        console2.log("  segments crossed", crossedThree);
    }

    // =====================================================================================================
    // Helpers: checks
    // =====================================================================================================

    function _assertSingleRange(PoolKey memory k, bool zfo, uint256 amount, string memory ctx) internal {
        PoolVenue.Pool memory p = _read(k, zfo, _lim(zfo));
        (uint256 q, uint256 used, uint256 touched) = PoolVenue.quoteExactIn(p, amount);
        Real memory r = _realise(k, zfo, -int256(amount), _lim(zfo));
        assertEq(touched, 1, string.concat(ctx, ": one range"));
        assertEq(used, amount, string.concat(ctx, ": used"));
        assertEq(r.amountIn, amount, string.concat(ctx, ": real input"));
        assertApproxEqAbs(q, r.amountOut, 2, string.concat(ctx, ": within 2 wei"));
        console2.log(ctx, "deviation (wei)", _absDiff(q, r.amountOut));
    }

    function _assertExactIn(PoolKey memory k, bool zfo, uint256 amount) internal {
        PoolVenue.Pool memory p = _read(k, zfo, _lim(zfo));
        (uint256 q, uint256 used,) = PoolVenue.quoteExactIn(p, amount);
        Real memory r = _realise(k, zfo, -int256(amount), _lim(zfo));
        assertEq(used, r.amountIn, "exact in: input used");
        assertEq(q, r.amountOut, "exact in: quote = chain");
    }

    function _assertExactOut(PoolKey memory k, bool zfo, uint256 amount) internal {
        PoolVenue.Pool memory p = _read(k, zfo, _lim(zfo));
        (uint256 q, uint256 given,) = PoolVenue.quoteExactOut(p, amount);
        Real memory r = _realise(k, zfo, int256(amount), _lim(zfo));
        assertEq(given, r.amountOut, "exact out: output given");
        assertEq(q, r.amountIn, "exact out: quote = chain");
    }

    function _assertLimit(PoolKey memory k, bool zfo, uint160 limit, uint256 count) internal {
        PoolVenue.Pool memory p = _read(k, zfo, limit);
        assertEq(p.segments.length, count, "segments up to the limit");
        assertEq(p.segments[count - 1].sqrtPriceEndX96, limit, "the list ends at the limit");
        assertFalse(p.truncated, "not truncated: the limit is a hard end");
        SplitMath.Venue[] memory v = PoolVenue.venues(p, true);
        assertEq(v[count - 1].cap, p.segments[count - 1].capIn, "last venue capped");
        uint256 sumIn;
        uint256 sumOut;
        for (uint256 i; i < count; i++) {
            sumIn += p.segments[i].capIn;
            sumOut += p.segments[i].capOut;
        }
        Real memory r = _realise(k, zfo, -int256(1e24), limit);
        assertEq(r.sqrtPriceAfter, limit, "the real swap stops at the limit");
        assertEq(r.amountIn, sumIn, "input = sum of capIn");
        assertEq(r.amountOut, sumOut, "output = sum of capOut");
    }

    function _assertEnds(PoolVenue.Pool memory p, uint256 i, int24 tick) internal pure {
        assertEq(p.segments[i].sqrtPriceEndX96, TickMath.getSqrtPriceAtTick(tick), "segment end tick");
    }

    function _assertPoolMatchesVector(PoolKey memory k, Vectors.PoolV memory v) internal view {
        (uint160 sqrtP, int24 tick,, uint24 lpFee) = manager.getSlot0(k.toId());
        assertEq(sqrtP, v.sqrtPriceX96, "vector sqrtPrice");
        assertEq(tick, v.tick, "vector tick");
        assertEq(lpFee, v.feePips, "vector fee");
        assertEq(k.tickSpacing, v.tickSpacing, "vector spacing");
        assertEq(manager.getLiquidity(k.toId()), v.liquidity, "vector liquidity");
        for (uint256 i; i < v.ticks.length; i++) {
            (, int128 net) = manager.getTickLiquidity(k.toId(), v.ticks[i]);
            assertEq(net, v.liquidityNets[i], "vector liquidityNet");
        }
    }

    function _checkCrossingCase(PoolKey memory k, Vectors.Crossing memory c) internal {
        bool zfo = c.pool.zeroForOne;
        PoolVenue.Pool memory p = _read(k, zfo, _lim(zfo));
        assertEq(p.segments.length, c.segments.length, string.concat(c.name, ": segment count"));
        for (uint256 j; j < c.segments.length; j++) {
            string memory ctx = string.concat(c.name, " segment ", vm.toString(j));
            assertEq(p.segments[j].x, c.segments[j].x, string.concat(ctx, ": x"));
            assertEq(p.segments[j].y, c.segments[j].y, string.concat(ctx, ": y"));
            assertEq(uint256(p.swapFee) * 1000, uint256(c.segments[j].feeE9), string.concat(ctx, ": fee"));
            assertEq(p.segments[j].capIn, c.segments[j].capIn, string.concat(ctx, ": capIn"));
            assertEq(p.segments[j].capOut, c.segments[j].capOut, string.concat(ctx, ": capOut"));
            assertEq(p.segments[j].liquidity, c.segments[j].liquidity, string.concat(ctx, ": liquidity"));
        }

        SplitMath.Venue[] memory makers = new SplitMath.Venue[](1);
        makers[0] = _venueV(c.maker);
        SplitMath.Venue[] memory pv = PoolVenue.venues(p, c.exactIn);
        (uint256[] memory a, uint256 crossed) =
            c.exactIn ? SplitMath.solveExactIn(pv, makers, c.amount) : SplitMath.solveExactOut(pv, makers, c.amount);
        assertEq(a[0] + a[1], c.amount, string.concat(c.name, ": sum"));
        assertApproxEqAbs(a[1], c.allocMaker, c.amount / E9, string.concat(c.name, ": maker share"));
        assertEq(crossed, c.rangesCrossed, string.concat(c.name, ": ranges crossed"));

        uint256 total;
        if (c.exactIn) {
            (uint256 q,, uint256 touched) = PoolVenue.quoteExactIn(p, a[0]);
            Real memory r = _realise(k, zfo, -int256(a[0]), _lim(zfo));
            assertEq(r.amountIn, a[0], string.concat(c.name, ": real pool input"));
            assertEq(q, r.amountOut, string.concat(c.name, ": pool leg = quote"));
            if (a[0] == c.allocPool) assertEq(r.amountOut, c.poolLeg, string.concat(c.name, ": pool leg = vector"));
            assertEq(touched - 1, c.ticksCrossed, string.concat(c.name, ": ticks crossed"));
            total = r.amountOut + (a[1] > 0 ? _cpOutInt(makers[0], a[1]) : 0);
        } else {
            (uint256 q,, uint256 touched) = PoolVenue.quoteExactOut(p, a[0]);
            Real memory r = _realise(k, zfo, int256(a[0]), _lim(zfo));
            assertEq(r.amountOut, a[0], string.concat(c.name, ": real pool output"));
            assertEq(q, r.amountIn, string.concat(c.name, ": pool leg = quote"));
            if (a[0] == c.allocPool) assertEq(r.amountIn, c.poolLeg, string.concat(c.name, ": pool leg = vector"));
            assertEq(touched - 1, c.ticksCrossed, string.concat(c.name, ": ticks crossed"));
            total = r.amountIn + (a[1] > 0 ? _cpInInt(makers[0], a[1]) : 0);
        }
        assertApproxEqRel(total, c.totalInt, 1e9, string.concat(c.name, ": total"));
        console2.log(c.name, "maker share", a[1]);
        console2.log("  vector", c.allocMaker);
    }

    // =====================================================================================================
    // Helpers: pools and swaps
    // =====================================================================================================

    /// @dev The V2-00 crossing pool (reference/gen_vectors.py CROSSING_TICKS): nested positions at price 1.
    function _crossingPool() internal returns (PoolKey memory) {
        Pos[] memory pos = new Pos[](3);
        pos[0] = Pos(-180, 180, 1e22);
        pos[1] = Pos(-120, 120, 2e22);
        pos[2] = Pos(-60, 60, 3e22);
        return _newPool(pos, POOL_FEE);
    }

    function _overlapPool() internal returns (PoolKey memory) {
        Pos[] memory pos = new Pos[](3);
        pos[0] = Pos(-600, 600, 1e22);
        pos[1] = Pos(-300, -60, 2e22);
        pos[2] = Pos(-480, -180, 3e22);
        return _newPool(pos, POOL_FEE);
    }

    /// @dev Deep liquidity on [-480, 600], seven small positions making ticks at -60 ... -420, a gap on [-540, -480]
    ///      and deep liquidity again on [-1200, -540]. Zero for one from tick 0, the 8th segment ends at -480.
    function _gapPool() internal returns (PoolKey memory) {
        Pos[] memory pos = new Pos[](9);
        pos[0] = Pos(-480, 600, 1e22);
        for (uint256 i; i < 7; i++) {
            pos[i + 1] = Pos(-60 * int24(int256(i + 1)), 600, 1e20);
        }
        pos[8] = Pos(-1200, -540, 1e22);
        return _newPool(pos, POOL_FEE);
    }

    function _tenTickPool() internal returns (PoolKey memory) {
        Pos[] memory pos = new Pos[](10);
        for (uint256 i; i < 10; i++) {
            pos[i] = Pos(-60 * int24(int256(i + 1)), 1200, 1e21);
        }
        return _newPool(pos, POOL_FEE);
    }

    /// @dev A hookless pool (spacing 60) of two fresh 18-decimal tokens at price 1 (tick 0), with `pos` added by the
    ///      deployer. The trader is funded and approves the swap router.
    function _newPool(Pos[] memory pos, uint24 fee) internal returns (PoolKey memory k) {
        vm.startPrank(deployer);
        address t0 = address(new MockMUMB());
        address t1 = address(new MockMUMB());
        vm.stopPrank();
        if (t1 < t0) (t0, t1) = (t1, t0);
        k = PoolKey(Currency.wrap(t0), Currency.wrap(t1), fee, TICK_SPACING, IHooks(address(0)));
        manager.initialize(k, uint160(FixedPoint96.Q96));
        _fund(t0);
        _fund(t1);
        vm.startPrank(deployer);
        for (uint256 i; i < pos.length; i++) {
            liquidityRouter.modifyLiquidity(
                k,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: pos[i].lower,
                    tickUpper: pos[i].upper,
                    liquidityDelta: int256(uint256(pos[i].liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
        }
        vm.stopPrank();
    }

    function _fund(address token) internal {
        deal(token, deployer, 1e30);
        deal(token, trader, 1e30);
        vm.prank(deployer);
        IERC20(token).approve(address(liquidityRouter), type(uint256).max);
    }

    /// @dev One pool-only swap by the trader from the current state, then the state is restored.
    function _realise(PoolKey memory k, bool zfo, int256 amountSpecified, uint160 limit)
        internal
        returns (Real memory r)
    {
        uint256 snap = vm.snapshotState();
        vm.startPrank(trader);
        IERC20(Currency.unwrap(k.currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(k.currency1)).approve(address(swapRouter), type(uint256).max);
        BalanceDelta d = swapRouter.swap(
            k,
            IPoolManager.SwapParams({zeroForOne: zfo, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        (int128 d0, int128 d1) = (d.amount0(), d.amount1());
        (int128 dIn, int128 dOut) = zfo ? (d0, d1) : (d1, d0);
        r.amountIn = uint256(uint128(-dIn));
        r.amountOut = uint256(uint128(dOut));
        (r.sqrtPriceAfter, r.tickAfter,,) = manager.getSlot0(k.toId());
        require(vm.revertToStateAndDelete(snap), "revert failed");
    }

    function _read(PoolKey memory k, bool zfo, uint160 limit) internal view returns (PoolVenue.Pool memory) {
        return PoolVenue.read(manager, k.toId(), k.tickSpacing, zfo, limit);
    }

    function _lim(bool zfo) internal pure returns (uint160) {
        return zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _venueV(Vectors.VenueV memory w) internal pure returns (SplitMath.Venue memory) {
        return SplitMath.Venue(w.x, w.y, w.feeE9, w.cap);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}

/// @dev Holds a tick bitmap in its own storage so v4's `TickBitmap` can run on it. Test-only.
contract TickBitmapHarness {
    mapping(int16 => uint256) internal bitmap;

    function set(int16 wordPos, uint256 word) external {
        bitmap[wordPos] = word;
    }

    function next(int24 tick, int24 tickSpacing, bool lte) external view returns (int24, bool) {
        return TickBitmap.nextInitializedTickWithinOneWord(bitmap, tick, tickSpacing, lte);
    }
}

/// @notice V2-02, no fork: the TickBitmap port and the piecewise solver's properties (D-29 carry-overs included).
contract V202PiecewiseTest is Test, SplitHelpers {
    uint256 internal constant NONE = type(uint256).max;
    uint256 internal constant MAX_AMOUNT = type(uint128).max;

    TickBitmapHarness internal harness;

    function setUp() public {
        harness = new TickBitmapHarness();
    }

    /// @dev PoolVenue's port of `nextInitializedTickWithinOneWord` equals v4's on any word, tick, spacing, direction.
    function testFuzz_V202_nextTickMatchesTickBitmap(uint256 word, int256 tickSeed, uint256 spacingSeed, bool lte)
        public
    {
        int24 spacing = int24(int256(1 + spacingSeed % uint256(int256(TickMath.MAX_TICK_SPACING))));
        int24 tick = int24(bound(tickSeed, TickMath.MIN_TICK, TickMath.MAX_TICK));
        int24 compressed = TickBitmap.compress(tick, spacing);
        (int16 wordPos,) = TickBitmap.position(lte ? compressed : compressed + 1);
        harness.set(wordPos, word);
        (int24 want, bool wantInit) = harness.next(tick, spacing, lte);
        (int24 got, bool gotInit) = PoolVenue.nextInWord(word, tick, spacing, lte);
        assertEq(got, want, "next tick");
        assertEq(gotInit, wantInit, "initialised flag");
    }

    /// @dev D-29 carry-over 1: SplitMath alone gives a dust-sized range (y = 302) a remainder past its reserve when the
    ///      trade nearly drains every venue. The piecewise solve turns that into a crossing.
    function test_V202_exactOutPastReserveCrosses() public pure {
        uint32 fee = 3_000_000;
        SplitMath.Venue memory dust = SplitMath.Venue(302, 302, fee, 301); // a range whose end gives 301 of 302
        SplitMath.Venue memory next = SplitMath.Venue(1e22, 1e22, fee, NONE);
        SplitMath.Venue memory maker = SplitMath.Venue(1e22, 1e22, fee, NONE);
        uint256 amount = 302 + 1e22 - 5;

        SplitMath.Venue[] memory single = new SplitMath.Venue[](2);
        single[0] = SplitMath.Venue(dust.x, dust.y, fee, NONE);
        single[1] = maker;
        uint256[] memory s = SplitMath.solveExactOut(single, amount);
        assertGe(s[0], dust.y, "precondition: one curve puts the pool past its reserve (D-29)");

        SplitMath.Venue[] memory pool = new SplitMath.Venue[](2);
        pool[0] = dust;
        pool[1] = next;
        SplitMath.Venue[] memory makers = new SplitMath.Venue[](1);
        makers[0] = maker;
        (uint256[] memory b, uint256 crossed) = SplitMath.solveExactOut(pool, makers, amount);
        assertEq(crossed, 1, "the pool crosses into the next range");
        assertEq(b[0] + b[1], amount, "sum");
        assertGe(b[0], dust.cap, "the dust range is used up");
        assertLt(b[1], maker.y, "the maker is not drained");
        assertEq(pool[0].cap, 301, "the caller's segments are not modified");
    }

    /// @dev D-29 carry-over 1, no next range: the only range is hard-capped and the makers are capped, so nobody can
    ///      take the rest. No revert; the pool is past its range (`crossed == length`); makers at their caps.
    function test_V202_noNextRangeDoesNotRevert() public pure {
        uint32 fee = 3_000_000;
        SplitMath.Venue[] memory pool = new SplitMath.Venue[](1);
        SplitMath.Venue[] memory makers = new SplitMath.Venue[](1);
        makers[0] = SplitMath.Venue(1e22, 1e22, fee, 1e21);

        pool[0] = SplitMath.Venue(302, 302, fee, 301);
        (uint256[] memory b, uint256 crossed) = SplitMath.solveExactOut(pool, makers, 2e21);
        assertEq(b[0] + b[1], 2e21, "out: sum");
        assertEq(b[1], 1e21, "out: maker at its cap");
        assertEq(crossed, 1, "out: past the only range");
        assertGt(b[0], pool[0].y, "out: the pool's share is past its reserve");

        pool[0] = SplitMath.Venue(1_000, 1_000, fee, 500);
        (uint256[] memory a, uint256 crossedIn) = SplitMath.solveExactIn(pool, makers, 2e21);
        assertEq(a[0] + a[1], 2e21, "in: sum");
        assertEq(a[1], 1e21, "in: maker at its cap");
        assertEq(crossedIn, 1, "in: past the only range");
    }

    /// @dev A share exactly at a segment's cap crosses (`>=`, mutation M10): the next segment, priced better here, then
    ///      takes more. Synthetic segments, so the jump in price makes the difference visible.
    function test_V202_shareAtCapCrosses() public pure {
        uint32 fee = 3_000_000;
        SplitMath.Venue memory maker = SplitMath.Venue(1e22, 1e22, fee, NONE);
        for (uint256 mode; mode < 2; mode++) {
            bool exactIn = mode == 0;
            uint256 amount = 1e21;
            SplitMath.Venue[] memory one = new SplitMath.Venue[](2);
            one[0] = SplitMath.Venue(1e22, 1e22, fee, NONE);
            one[1] = maker;
            uint256 share = (exactIn ? SplitMath.solveExactIn(one, amount) : SplitMath.solveExactOut(one, amount))[0];

            SplitMath.Venue[] memory pool = new SplitMath.Venue[](2);
            pool[0] = SplitMath.Venue(1e22, 1e22, fee, share); // the free share lands exactly on the cap
            pool[1] = SplitMath.Venue(1e22, 2e22, fee, NONE); // a better price after the cap
            SplitMath.Venue[] memory makers = new SplitMath.Venue[](1);
            makers[0] = maker;
            (uint256[] memory a, uint256 crossed) =
                exactIn ? SplitMath.solveExactIn(pool, makers, amount) : SplitMath.solveExactOut(pool, makers, amount);
            assertEq(crossed, 1, "a share at the cap crosses");
            assertGt(a[0], share, "the next segment takes more");
            assertEq(a[0] + a[1], amount, "sum");
        }
    }

    /// @dev A hard last cap with makers that have room (mutation M11): the pool stops exactly at its capacity and the
    ///      maker takes the rest, both modes. `crossed == length` here, yet the pool's share is fillable: the V2-07
    ///      carry-over (a) is only the case where the share is past the capacity.
    function test_V202_hardLastCapPinsPool() public pure {
        uint32 fee = 3_000_000;
        SplitMath.Venue[] memory pool = new SplitMath.Venue[](2);
        pool[0] = SplitMath.Venue(1e22, 1e22, fee, 5e19);
        pool[1] = SplitMath.Venue(1.01e22, 0.99e22, fee, 5e19);
        SplitMath.Venue[] memory makers = new SplitMath.Venue[](1);
        makers[0] = SplitMath.Venue(1e22, 1e22, fee, NONE);
        for (uint256 mode; mode < 2; mode++) {
            (uint256[] memory a, uint256 crossed) =
                mode == 0 ? SplitMath.solveExactIn(pool, makers, 1e21) : SplitMath.solveExactOut(pool, makers, 1e21);
            assertEq(a[0], 1e20, "the pool stops at its hard end");
            assertEq(a[1], 1e21 - 1e20, "the maker takes the rest");
            assertEq(crossed, 2, "every walked segment is filled");
        }
    }

    /// @dev Random contiguous segment chains (built with `PoolVenue.segment`) and 0 to 7 makers, both modes: the
    ///      parts sum, makers keep their caps, and `crossed` names the segment the pool's share ends in.
    function testFuzz_V202_piecewiseSumsAndCaps(uint256 seed, uint256 amountSeed) public pure {
        for (uint256 mode; mode < 2; mode++) {
            bool exactIn = mode == 0;
            bool zfo = _word(seed, 0, 30) % 2 == 0;
            SplitMath.Venue[] memory pool = _chain(seed, zfo, exactIn);
            SplitMath.Venue[] memory makers = _makers(seed, pool[0]);
            uint256 capacity;
            for (uint256 i; i < pool.length; i++) {
                if (pool[i].cap != NONE) capacity += pool[i].cap;
            }
            uint256 hi = exactIn ? 2 * capacity + 1 : capacity + _sumMakerY(makers) / 2 + 1;
            if (hi > MAX_AMOUNT) hi = MAX_AMOUNT;
            // Half the amounts anywhere from 1 wei, half within 64x of the bound, so many runs cross segments (D-30).
            uint256 amount = _logUniform(amountSeed, amountSeed % 2 == 0 ? 1 : hi / 64, hi);
            for (uint256 j; j < makers.length; j++) {
                if (_word(seed, j, 31) % 2 == 0) makers[j].cap = _logUniform(_word(seed, j, 32), 1, amount);
            }

            (uint256[] memory a, uint256 crossed) =
                exactIn ? SplitMath.solveExactIn(pool, makers, amount) : SplitMath.solveExactOut(pool, makers, amount);
            assertEq(a.length, makers.length + 1, "length");
            assertEq(_sum(a), amount, "sum");
            for (uint256 j; j < makers.length; j++) {
                assertLe(a[j + 1], makers[j].cap, "maker above its cap");
                if (!exactIn) assertLt(a[j + 1], makers[j].y, "maker asked for its whole reserve");
            }
            assertLe(crossed, pool.length, "crossed");
            uint256 prefix;
            for (uint256 i; i < crossed; i++) {
                prefix += pool[i].cap;
            }
            assertGe(a[0], prefix, "the pool fills every range it crosses");
            if (crossed < pool.length) {
                assertLt(a[0] - prefix, pool[crossed].cap, "the pool ends inside the range `crossed`");
            } else if (exactIn && a[0] > prefix + makers.length + 1) {
                // Past a hard end (beyond index 0's rounding remainder) only when no maker has room (mutation M11).
                for (uint256 j; j < makers.length; j++) {
                    assertEq(a[j + 1], makers[j].cap, "the pool is past its hard end while a maker has room");
                }
            }
        }
    }

    /// @dev Never reverts: any lengths (0 to 10 segments and makers), values biased to the envelope edge.
    function testFuzz_V202_piecewiseNeverReverts(uint256 seed, uint8 nPool, uint8 nMakers, uint256 amountSeed)
        public
        pure
    {
        SplitMath.Venue[] memory pool = new SplitMath.Venue[](nPool % 11);
        SplitMath.Venue[] memory makers = new SplitMath.Venue[](nMakers % 11);
        for (uint256 i; i < pool.length; i++) {
            pool[i] = _edgyVenue(seed, i);
        }
        for (uint256 j; j < makers.length; j++) {
            makers[j] = _edgyVenue(seed, 100 + j);
        }
        uint256 amount = _edgy(amountSeed);
        for (uint256 mode; mode < 2; mode++) {
            (uint256[] memory a, uint256 crossed) =
                mode == 0 ? SplitMath.solveExactIn(pool, makers, amount) : SplitMath.solveExactOut(pool, makers, amount);
            assertEq(a.length, makers.length + 1, "length");
            assertEq(_sum(a), amount, "sum");
            assertLe(crossed, pool.length, "crossed");
        }
    }

    // ------------------------------------------------------------------ generators

    /// @dev 1 to 8 contiguous segments from a random start tick (|tick| <= 100,000), widths 1 to 20 spacings of 60,
    ///      liquidity 1e9 to 1e27, one fee up to 1%. Half the chains are truncated (last venue uncapped).
    function _chain(uint256 seed, bool zfo, bool exactIn) internal pure returns (SplitMath.Venue[] memory pool) {
        uint256 k = 1 + _word(seed, 0, 20) % 8;
        int24 tick = int24(int256(_word(seed, 0, 21) % 200_001) - 100_000);
        uint24 fee = uint24(_word(seed, 0, 22) % 10_001);
        uint160 sp = TickMath.getSqrtPriceAtTick(tick);
        pool = new SplitMath.Venue[](k);
        for (uint256 i; i < k; i++) {
            int24 width = int24(int256(1 + _word(seed, i, 23) % 20)) * 60;
            tick = zfo ? tick - width : tick + width;
            uint160 end = TickMath.getSqrtPriceAtTick(tick);
            uint128 liq = uint128(_logUniform(_word(seed, i, 24), 1e9, 1e27));
            PoolVenue.Segment memory s = PoolVenue.segment(sp, end, liq, fee, zfo);
            pool[i] = SplitMath.Venue(s.x, s.y, uint32(fee) * 1000, exactIn ? s.capIn : s.capOut);
            sp = end;
        }
        if (_word(seed, 0, 25) % 2 == 0) pool[k - 1].cap = NONE;
    }

    /// @dev 0 to 7 makers, reserves 1e9 to 1e27, prices within [0.5, 2] of the pool's starting price, fees below 1%.
    function _makers(uint256 seed, SplitMath.Venue memory first) internal pure returns (SplitMath.Venue[] memory m) {
        m = new SplitMath.Venue[](_word(seed, 0, 26) % 8);
        for (uint256 j; j < m.length; j++) {
            uint256 x = _logUniform(_word(seed, j, 27), 1e9, 1e27);
            uint256 d = 5e17 + _word(seed, j, 28) % 15e17;
            uint256 y = FullMath.mulDiv(FullMath.mulDiv(x, first.y, first.x), d, 1e18);
            m[j] = SplitMath.Venue(x, y == 0 ? 1 : y, uint32(_word(seed, j, 29) % 1e7), NONE);
        }
    }

    function _edgyVenue(uint256 seed, uint256 i) internal pure returns (SplitMath.Venue memory v) {
        v.x = _edgy(_word(seed, i, 1));
        v.y = _edgy(_word(seed, i, 2));
        v.feeE9 = uint32(_word(seed, i, 3));
        v.cap = _edgy(_word(seed, i, 4));
    }

    function _sumMakerY(SplitMath.Venue[] memory m) internal pure returns (uint256 s) {
        for (uint256 j; j < m.length; j++) {
            s += m[j].y;
        }
    }
}
