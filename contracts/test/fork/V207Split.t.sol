// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BandExceeded, TakerNotHook} from "../../src/BandGuardV2.sol";
import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {ConfluenceSplitter, IConfluenceHookView, LegStatus, Plan} from "../../src/ConfluenceSplitter.sol";
import {ConfluenceSplitterOut} from "../../src/ConfluenceSplitterOut.sol";
import {SplitMath} from "../../src/libraries/SplitMath.sol";
import {MakerVenue} from "../../src/libraries/MakerVenue.sol";
import {PoolVenue} from "../../src/libraries/PoolVenue.sol";
import {StrategyTemplate} from "../../src/libraries/StrategyTemplate.sol";
import {PoolPriceBandExtruction} from "../../src/v1/PoolPriceBandExtruction.sol";
import {SplitBase, MinOutRouter, V207Helpers} from "../base/SplitBase.t.sol";
import {UnichainBase} from "../base/UnichainBase.t.sol";
import {Vectors} from "../base/Vectors.sol";

/// @notice V2-07: the hint-free split in `beforeSwap` (gate M3) on the mainnet fork.
/// @dev Venues are read at the hook's post-update anchor; the splitter plans, the hook checks the plan and runs the
///      legs. Every comparison with pool-only uses the pool's real output from a real swap on the same snapshot, with
///      the makers unregistered (the pool's state is the same: registering changes no pool state).
contract V207SplitTest is SplitBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // =====================================================================================================
    // Spec acceptance
    // =====================================================================================================

    /// @dev Whatever `hookData` holds (empty, a v1 hint, junk), the split is the same.
    function test_V207_emptyHookDataGetsSplit() public {
        _initExact(keyV2);
        _threeMakers();
        uint256 s = vm.snapshotState();
        Run memory a = _run(keyV2, true, 1_000 * USDC_1, "");
        vm.revertToState(s);
        Run memory b = _run(keyV2, true, 1_000 * USDC_1, abi.encode(uint256(550_000_000)));
        vm.revertToState(s);
        Run memory c = _run(keyV2, true, 1_000 * USDC_1, hex"deadbeef");
        assertEq(_countStatus(a.legs, LegStatus.FILLED), 3, "three legs with empty hookData");
        assertEq(a.got, b.got, "a v1 hint changes nothing");
        assertEq(a.got, c.got, "junk hookData changes nothing");
        for (uint256 i; i < 3; i++) {
            assertEq(a.legs[i].amountIn, b.legs[i].amountIn, "same legs (hint)");
            assertEq(a.legs[i].amountIn, c.legs[i].amountIn, "same legs (junk)");
        }
    }

    /// @dev Gate M3. The anchor is recorded by a swap of 1 raw USDC: the fee takes all of it, so the price does not
    ///      move and the pool is exactly the v1 demo pool (pool-only equals D-21 to the wei). Then one maker with
    ///      Priya's strategy shape and balances (100,000 / 100,000, 0.30%).
    function test_V207_atLeastV1Best() public {
        string memory json = Vectors.read(Vectors.V1_DEMO);
        Vectors.V1Case memory c = Vectors.v1Case(json, 0);
        _initExact(keyV2);
        M[] memory ms = new M[](1);
        ms[0] = _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());

        uint256 poolOnly = _poolOnly(keyV2, true, c.amount).got;
        assertEq(poolOnly, c.poolOnlyOut, "premise: the pool is the v1 demo pool");

        Book memory b0 = _book(ms);
        Run memory r = _run(keyV2, true, c.amount, "");
        Book memory b1 = _book(ms);
        _assertBooks(b0, b1, true, c.amount, r, ms);

        console2.log("M3: realised (empty hookData)     ", r.got);
        console2.log("M3: closed-form target (V2-00)     ", c.totalInt);
        console2.log("M3: v1 hinted best (D-21, gate)    ", c.hintTotal);
        console2.log("M3: pool-only (real swap)          ", poolOnly);
        console2.log("M3: maker share (USDC raw)         ", r.legs[0].amountIn);
        console2.log("M3: closed-form share (USDC raw)   ", c.allocPriya);
        assertEq(c.hintTotal, M3_TARGET, "vector carries D-21's hinted best");
        assertGe(r.got, M3_TARGET, "M3: at least v1's hinted best");
        assertEq(r.legs[0].status, LegStatus.FILLED, "filled");
    }

    /// @dev The four v1 demo cases (both directions, a word-edge crossing) against the V2-00 closed form.
    function test_V207_bothDirections() public {
        string memory json = Vectors.read(Vectors.V1_DEMO);
        _initExact(keyV2);
        M[] memory ms = new M[](1);
        ms[0] = _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
        uint256 n = Vectors.count(json);
        assertEq(n, 4, "cases");
        for (uint256 i; i < n; i++) {
            Vectors.V1Case memory c = Vectors.v1Case(json, i);
            bool zfo = c.pool.zeroForOne;
            uint256 s = vm.snapshotState();
            uint256 poolOnly = _poolOnly(keyV2, zfo, c.amount).got;
            assertEq(poolOnly, c.poolOnlyOut, string.concat(c.name, ": pool-only"));
            Book memory b0 = _book(ms);
            Run memory r = _run(keyV2, zfo, c.amount, "");
            _assertBooks(b0, _book(ms), zfo, c.amount, r, ms);
            assertEq(r.legs[0].status, LegStatus.FILLED, c.name);
            // V2-01/V2-02 tolerance for the integer solve against the real-valued closed form (D-29).
            assertApproxEqAbs(r.legs[0].amountIn, c.allocPriya, c.amount / 1e9, string.concat(c.name, ": share"));
            assertGt(r.got, poolOnly, string.concat(c.name, ": better than pool-only"));
            console2.log(c.name, r.got, c.totalInt);
            vm.revertToState(s);
        }
    }

    /// @dev The v1 pool and three makers with different fees and depths (`threeMakers` in v1_demo.json): realised
    ///      allocations, legs and total equal the integer-mode reference to the wei.
    function test_V207_threeMakersMatchVectors() public {
        string memory json = Vectors.read(Vectors.V1_DEMO);
        _initExact(keyV2);
        M[] memory ms = _threeMakers();
        uint256 n = Vectors.threeMakersCount(json);
        assertEq(n, 2, "cases");
        for (uint256 i; i < n; i++) {
            Vectors.ThreeMakers memory c = Vectors.threeMakers(json, i);
            uint256 s = vm.snapshotState();
            assertEq(_poolOnly(keyV2, c.zeroForOne, c.amount).got, c.poolOnlyOut, string.concat(c.name, ": pool"));
            Book memory b0 = _book(ms);
            Run memory r = _run(keyV2, c.zeroForOne, c.amount, "");
            _assertBooks(b0, _book(ms), c.zeroForOne, c.amount, r, ms);
            uint256 iOut = c.zeroForOne ? 1 : 0;
            uint256 poolLeg = b0.pm[iOut] - _book(ms).pm[iOut];
            for (uint256 j; j < 3; j++) {
                console2.log(c.name, j, r.legs[j].amountIn, c.alloc[j + 1]);
                assertEq(r.legs[j].status, LegStatus.FILLED, string.concat(c.name, ": filled"));
                assertEq(r.legs[j].amountIn, c.alloc[j + 1], string.concat(c.name, ": allocation"));
                assertEq(r.legs[j].amountOut, c.perVenue[j + 1], string.concat(c.name, ": leg output"));
            }
            assertEq(poolLeg, c.perVenue[0], string.concat(c.name, ": pool leg"));
            assertEq(r.got, c.totalInt, string.concat(c.name, ": total"));
            vm.revertToState(s);
        }
    }

    /// @dev One maker's router call reverts (mocked for exactly that order and amount); the swap succeeds, the pool
    ///      fills that share, the status is SKIP_REVERT, and the result is still no worse than pool-only.
    function test_V207_failedLegFallsToPool() public {
        _initExact(keyV2);
        M[] memory ms = _threeMakers();
        uint256 amount = 1_000 * USDC_1;
        uint256 poolOnly = _poolOnly(keyV2, true, amount).got;
        Plan memory p = _plan(keyV2, true, amount);
        _mockLegRevert(keyV2, ms[1], true, p.amountIn[1], p.amountOut[1]);

        Book memory b0 = _book(ms);
        Run memory r = _run(keyV2, true, amount, "");
        _assertBooks(b0, _book(ms), true, amount, r, ms);
        assertEq(r.legs[1].status, LegStatus.SKIP_REVERT, "SKIP_REVERT");
        assertEq(r.legs[1].amountIn, 0, "nothing filled");
        assertEq(r.legs[0].status, LegStatus.FILLED, "others fill");
        assertEq(r.legs[2].status, LegStatus.FILLED, "others fill");
        assertEq(r.legs[0].amountIn, p.amountIn[0], "planned amount");
        assertGe(r.got, poolOnly, "still no worse than pool-only");
    }

    /// @dev After swaps in both directions, one with a failed leg: the hook holds nothing and no approval is left.
    function test_V207_hookHoldsNothing() public {
        _initExact(keyV2);
        M[] memory ms = _threeMakers();
        Plan memory p = _plan(keyV2, true, 800 * USDC_1);
        _mockLegRevert(keyV2, ms[2], true, p.amountIn[2], p.amountOut[2]);
        Run memory r = _run(keyV2, true, 800 * USDC_1, "");
        assertEq(r.legs[2].status, LegStatus.SKIP_REVERT, "premise: a failed leg");
        _assertClean();
        vm.clearMockedCalls();
        _run(keyV2, false, 700 * MUMB_1, "");
        _assertClean();
        _run(keyV2, true, 50 * USDC_1, "");
        _assertClean();
    }

    function test_V207_noMakersIsPoolOnly() public {
        string memory json = Vectors.read(Vectors.V1_DEMO);
        Vectors.V1Case memory c = Vectors.v1Case(json, 0);
        _initExact(keyV2);
        Run memory r = _run(keyV2, true, c.amount, "");
        assertEq(r.got, c.poolOnlyOut, "pool-only to the wei");
        assertTrue(r.emitted, "one ConfluenceSwap");
        assertEq(r.legs.length, 0, "no legs");
        _assertClean();
    }

    /// @dev Named risk 2. The fuzz draws the pool shape (the v1 pool, or a pool whose walk is truncated with deep
    ///      liquidity after a gap), direction, size, 0-6 makers with prices within the band. The comparison is the
    ///      pool's real output from a real pool-only swap on the same snapshot.
    function testFuzz_V207_neverWorseThanPoolOnly(uint256 seed, bool zfo, uint256 amountRaw, uint8 nRaw, bool gap)
        public
    {
        _neverWorseCase(seed, zfo, amountRaw, nRaw, gap, false);
    }

    /// @dev The fuzz body over fixed seeds, counting what it covered: makers filled, the not-better fallback, no
    ///      makers, and the truncated shape. Each must occur. Seeds 0-23 use the fuzz's own domain; seeds 24-31 use a
    ///      coverage-only generator (thin makers with a 6% band on the truncated pool, the amount just past the walk),
    ///      because the wide domain's makers are deep enough to keep the pool's share inside the walk, so it never
    ///      reaches the not-better fallback (0 of 24 before this generator was added).
    function test_V207_neverWorseCoverage() public {
        uint256[5] memory seen; // filled, not better, none registered or none planned, truncated shape, pool-only
        for (uint256 i; i < COVERAGE_SEEDS; i++) {
            uint256 s = vm.snapshotState();
            uint256 h = uint256(keccak256(abi.encode("coverage", i)));
            bool thin = i >= COVERAGE_WIDE_SEEDS;
            bool gap = thin || (h >> 24) % 3 == 0;
            uint8 cat = _neverWorseCase(h, h % 2 == 0, h >> 8, uint8(h >> 16), gap, thin);
            seen[cat]++;
            if (gap) seen[3]++;
            vm.revertToState(s);
        }
        console2.log("coverage: some leg filled        ", seen[0]);
        console2.log("coverage: SKIP_NOT_BETTER         ", seen[1]);
        console2.log("coverage: nothing planned          ", seen[2]);
        console2.log("coverage: truncated-walk pool      ", seen[3]);
        assertGt(seen[0], 0, "coverage: fills");
        assertGt(seen[1], 0, "coverage: not-better fallback");
        assertGt(seen[2], 0, "coverage: nothing planned");
        assertGt(seen[3], 0, "coverage: truncated shape");
    }

    // =====================================================================================================
    // Named risk 2 and carry-overs 5-6: fixed cases
    // =====================================================================================================

    /// @dev Truncated walk, the pool's share within it: the split runs, priced with the tail bound, and beats the
    ///      real pool-only swap (which goes past the walk).
    function test_V207_truncatedShareInsideWalkSplits() public {
        PoolKey memory k = _gapKey();
        _initExact(k);
        M[] memory ms = new M[](1);
        ms[0] = _joinM(k, makers[0], 100_000e18, 100_000e6, _p());
        uint256 walked = _walked(k, true);
        uint256 amount = walked + walked / 5;
        Plan memory p = _plan(k, true, amount);
        assertEq(p.truncated, 1, "premise: truncated");
        assertLe(p.poolIn, walked, "premise: the pool's share is within the walk");
        assertGt(p.tail, 0, "premise: a tail is priced");
        uint256 poolOnly = _poolOnly(k, true, amount).got;
        Book memory b0 = _book(ms);
        Run memory r = _run(k, true, amount, "");
        _assertBooks(b0, _book(ms), true, amount, r, ms);
        assertEq(r.legs[0].status, LegStatus.FILLED, "filled");
        assertGe(r.got, poolOnly, "never worse");
    }

    /// @dev Truncated walk, the pool's share past it (a thin maker cannot take the rest): exact pool-only.
    function test_V207_truncatedShareBeyondWalkFallsBack() public {
        PoolKey memory k = _gapKey();
        _initExact(k);
        StrategyTemplate.Params memory wide = _p();
        wide.bandBps = 600;
        M[] memory ms = new M[](1);
        ms[0] = _joinM(k, makers[0], 2_000e18, 2_000e6, wide);
        uint256 walked = _walked(k, true);
        uint256 amount = walked + 100 * USDC_1;
        Plan memory p = _plan(k, true, amount);
        assertEq(p.status[0], LegStatus.SKIP_NOT_BETTER, "the splitter's own rule");
        uint256 poolOnly = _poolOnly(k, true, amount).got;
        Book memory b0 = _book(ms);
        Run memory r = _run(k, true, amount, "");
        _assertBooks(b0, _book(ms), true, amount, r, ms);
        assertEq(r.legs[0].status, LegStatus.SKIP_NOT_BETTER, "not better");
        assertEq(r.got, poolOnly, "exact pool-only");
    }

    /// @dev A hard price limit inside the walk and a capped maker that cannot take the rest (carry-over 5): the pool
    ///      fills only to the limit, as pool-only does, and the split's output is still at least pool-only's.
    function test_V207_hardLimitInsideWalk() public {
        _initExact(keyV2);
        M[] memory ms = new M[](1);
        ms[0] = _joinM(keyV2, makers[1], 20_000e18, 20_000e6, _pf(FEE_005));
        (, int24 tick,,) = manager.getSlot0(idV2);
        uint160 limit = TickMath.getSqrtPriceAtTick(tick - 100);
        uint256 amount = 2_000 * USDC_1;

        uint256 s = vm.snapshotState();
        _unregisterAll(keyV2);
        (uint256 poolPaid, uint256 poolGot) = _swapLim(keyV2, true, amount, limit);
        vm.revertToState(s);
        assertLt(poolPaid, amount, "premise: pool-only stops at the limit");

        vm.recordLogs();
        (uint256 paid, uint256 got) = _swapLim(keyV2, true, amount, limit);
        (ConfluenceHook.Leg[] memory legs,) = _legsFrom(vm.getRecordedLogs(), address(hookV2));
        assertEq(legs[0].status, LegStatus.FILLED, "the capped maker fills");
        assertEq(paid, poolPaid + legs[0].amountIn, "the pool fills the same walk to the limit");
        assertEq(got, poolGot + legs[0].amountOut, "plus the maker's leg");
        assertGe(got, poolGot, "never worse");
        _assertClean();
    }

    // =====================================================================================================
    // Named risk 3: a maker breaks after the read
    // =====================================================================================================

    /// @dev The splitter's plan is taken while the maker is healthy, then the maker is docked, drained or revoked, or
    ///      the leg is forged past the guard's band. The plan is replayed (mocked); the router call fails and is
    ///      caught. Every allowance is 0 and the hook's balances are exact after each case.
    function test_V207_brokenMakerAfterReadFallsToPool() public {
        _initExact(keyV2);
        M[] memory ms = _threeMakers();
        uint256 amount = 2_000 * USDC_1;
        Plan memory p = _plan(keyV2, true, amount);
        assertGt(p.amountIn[1], 0, "premise: maker 1 has a leg");
        for (uint256 kind; kind < 4; kind++) {
            uint256 s = vm.snapshotState();
            Plan memory q = p;
            if (kind == 0) {
                vm.prank(ms[1].who);
                IAqua(AQUA).dock(ROUTER, ms[1].hash, _tokens());
            } else if (kind == 1) {
                vm.startPrank(ms[1].who);
                mumb.transfer(deployer, mumb.balanceOf(ms[1].who));
                vm.stopPrank();
            } else if (kind == 2) {
                vm.prank(ms[1].who);
                mumb.approve(AQUA, 0);
            } else {
                q = _forgePastBand(p, ms, amount);
            }
            vm.mockCall(
                address(splitter), abi.encodeWithSelector(ConfluenceSplitter.planExactIn.selector), abi.encode(q)
            );
            Book memory b0 = _book(ms);
            Run memory r = _run(keyV2, true, amount, "");
            Book memory b1 = _book(ms);
            assertEq(r.legs[1].status, LegStatus.SKIP_REVERT, "SKIP_REVERT");
            assertEq(r.legs[0].status, LegStatus.FILLED, "maker 0 fills");
            _assertBooks(b0, b1, true, amount, r, ms);
            _assertClean();
            vm.clearMockedCalls();
            vm.revertToState(s);
        }
    }

    /// @dev D-20's sweep for the split: at every transaction gas limit where the pool-only swap passes, the split
    ///      swap passes, for a legitimate plan, for legs that burn their gas (the guard etched with a gas burner),
    ///      and for a splitter that burns its gas.
    function test_V207_neverCostsTheSwapAtAnyGasLimit() public {
        _initExact(keyV2);
        _threeMakers();
        uint256 filled = _sweepGasLimits("legit");
        assertGt(filled, 5, "precondition: the sweep includes limits where the legs fill");
        uint256 s = vm.snapshotState();
        vm.etch(_guard(), _burnerCode());
        assertEq(_sweepGasLimits("legs burn"), 0, "burning legs never fill");
        vm.revertToState(s);
        vm.etch(address(splitter), _burnerCode());
        assertEq(_sweepGasLimits("plan burns"), 0, "a burning splitter never fills");
    }

    // =====================================================================================================
    // Named risk 6: anchor ordering
    // =====================================================================================================

    /// @dev The stored anchor fails the drift check and the post-update anchor passes: the leg fills (the venue saw
    ///      the post-update anchor) and the guard accepts it (it reads the same). The reverse: SKIP_DRIFT, never
    ///      SKIP_REVERT.
    function test_V207_anchorSameForVenueAndGuard() public {
        uint256 s = vm.snapshotState();
        // Case A. Block 1: snapshot at T0; spot pushed up by more than driftTicks. Block 2 (1 s later): snapshot at
        // the pushed tick, EMA still near T0, so the stored anchor drifts. Block 3, an hour later: the post-update EMA
        // has caught up.
        _initExact(keyV2);
        _swap(keyV2, trader, false, -int256(1_800 * MUMB_1), "");
        _nextBlock(1);
        _initExact(keyV2);
        (int24 snapA, int56 emaA,) = hookV2.anchorOfX(idV2);
        assertFalse(MakerVenue.driftPasses(snapA, emaA, 300), "premise: the stored anchor drifts");
        M[] memory ms = new M[](1);
        ms[0] = _joinM(keyV2, makers[0], _mumbAt(100_000e6, snapA), 100_000e6, _p());
        _nextBlock(3600);
        (int24 snapB, int56 emaB, bool fresh) = hookV2.anchorOfX(idV2);
        assertFalse(fresh, "premise: not yet stored");
        assertTrue(MakerVenue.driftPasses(snapB, emaB, 300), "premise: the post-update anchor passes");
        Run memory r = _run(keyV2, true, 500 * USDC_1, "");
        assertEq(r.legs[0].status, LegStatus.FILLED, "post-update anchor: filled");
        vm.revertToState(s);

        // Case B. Block 1: snapshot at T0, spot pushed, the maker registers. Block 2 (1 s later): the post-update
        // anchor drifts, the stored one did not.
        _initExact(keyV2);
        _swap(keyV2, trader, false, -int256(1_800 * MUMB_1), ""); // before the maker registers, so it moves spot
        ms[0] = _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
        (snapA, emaA,) = hookV2.anchorOfX(idV2);
        assertTrue(MakerVenue.driftPasses(snapA, emaA, 300), "premise: the stored anchor passes");
        _nextBlock(1);
        (snapB, emaB,) = hookV2.anchorOfX(idV2);
        assertFalse(MakerVenue.driftPasses(snapB, emaB, 300), "premise: the post-update anchor drifts");
        r = _run(keyV2, true, 500 * USDC_1, "");
        assertEq(r.legs[0].status, LegStatus.SKIP_DRIFT, "post-update anchor: SKIP_DRIFT, not SKIP_REVERT");
    }

    /// @dev A same-block push moves spot but not the snapshot: caps are unchanged, and a curve priced at the pushed
    ///      spot (out of band at the snapshot) is SKIP_BAND and does not fill.
    function test_V207_sameBlockPushKeepsCap() public {
        _initExact(keyV2);
        M[] memory ms = new M[](2);
        ms[0] = _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
        int24 snap = _snap();
        Plan memory before = _plan(keyV2, true, 1_000 * USDC_1);
        // The push runs with maker 0 out of the registry, so it moves only the pool; the same strategy re-registers.
        vm.prank(makers[0]);
        hookV2.unregister(keyV2);
        _swap(keyV2, trader, true, -int256(1_200 * USDC_1), ""); // spot down by more than 200 ticks
        _register(makers[0], _p());
        (, int24 spot,,) = manager.getSlot0(idV2);
        assertLt(spot, snap - 200, "premise: spot pushed");
        assertEq(_snap(), snap, "snapshot unmoved");
        ms[1] = _joinM(keyV2, makers[1], _mumbAt(100_000e6, spot), 100_000e6, _p());
        Plan memory afterPush = _plan(keyV2, true, 1_000 * USDC_1);
        assertEq(afterPush.capIn[0], before.capIn[0], "cap unchanged by the push");
        assertEq(afterPush.capMin[0], before.capMin[0], "smallest fill unchanged by the push");
        assertEq(afterPush.status[1], LegStatus.SKIP_BAND, "fresh at spot, stale at the snapshot");
        Book memory b0 = _book(ms);
        Run memory r = _run(keyV2, true, 1_000 * USDC_1, "");
        assertEq(r.legs[1].status, LegStatus.SKIP_BAND, "SKIP_BAND");
        _assertBooks(b0, _book(ms), true, 1_000 * USDC_1, r, ms);
    }

    // =====================================================================================================
    // Named risks 7 and 8
    // =====================================================================================================

    /// @dev The hook never calls `PoolManager.swap` (exactly one call, the router's) and returns no LP-fee override: on
    ///      a dynamic-fee pool (stored fee 0) the PoolManager's Swap event carries fee 0 and the pool leg is the
    ///      splitter's quote at slot0's fee.
    function test_V207_noFeeOverrideNoSelfSwap() public {
        PoolKey memory k = _newHookedPool(LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, _v1Positions());
        _initExact(k);
        M[] memory ms = new M[](1);
        ms[0] = _joinM(k, makers[0], 100_000e18, 100_000e6, _p());
        uint256 amount = 1_000 * USDC_1;
        Plan memory p = _plan(k, true, amount);
        assertGt(p.amountIn[0], 0, "premise: a leg");
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.swap.selector), 1);
        vm.recordLogs();
        _swap(k, trader, true, -int256(amount), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != IPoolManager.Swap.selector) continue;
            (, int128 a1,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            assertEq(fee, 0, "no LP-fee override: slot0's fee");
            assertEq(uint256(uint128(a1)), p.poolOut, "pool leg = the quote at slot0's fee");
            seen = true;
        }
        assertTrue(seen, "a Swap event");
        (ConfluenceHook.Leg[] memory legs,) = _legsFrom(logs, address(hookV2));
        assertEq(legs[0].status, LegStatus.FILLED, "filled");
    }

    // V2-08 retired `test_V207_exactOutputUnchanged` (D-36): it asserted that exact output stays pool-only with no
    // ConfluenceSwap, which V2-08 deliberately changes. V208ExactOut.t.sol covers exact output.

    // =====================================================================================================
    // The splitter is checked, not trusted (D-35)
    // =====================================================================================================

    function test_V207_constructorRejectsBadSplitter() public {
        ConfluenceSplitterOut out = splitterOut;
        vm.expectRevert(ConfluenceHook.InvalidSplitter.selector);
        new ConfluenceHook(manager, ConfluenceSplitter(address(0)), out);
        address noCode = makeAddr("noCode");
        vm.expectRevert(ConfluenceHook.InvalidSplitter.selector);
        new ConfluenceHook(manager, ConfluenceSplitter(noCode), out);
    }

    /// @dev Malformed returns and plans that fail each hook check: pool-only, every slot SKIP_PLAN, the real pool-only
    ///      output, makers untouched.
    function test_V207_garbageSplitterIsPoolOnly() public {
        _initExact(keyV2);
        M[] memory ms = _fourMakers();
        uint256 amount = 1_000 * USDC_1;
        Plan memory p = _plan(keyV2, true, amount);
        Run memory poolOnly = _poolOnly(keyV2, true, amount);
        assertEq(_countStatus(_statuses(p, 4), LegStatus.FILLED), 3, "premise: an honest plan with three legs");

        // Wrong lengths and a revert.
        _expectPoolOnly(abi.encode(uint256(1)), false, true, amount, poolOnly, ms, "32 bytes");
        _expectPoolOnly(new bytes(100_000), false, true, amount, poolOnly, ms, "100 kB");
        _expectPoolOnly(bytes.concat(abi.encode(p), hex"00"), false, true, amount, poolOnly, ms, "one byte long");
        _expectPoolOnly("", true, true, amount, poolOnly, ms, "reverts");

        // Right length, one check failing at a time.
        Plan memory q;
        q = _copy(p);
        q.poolIn += 1;
        _expectPoolOnly(abi.encode(q), false, true, amount, poolOnly, ms, "sum != amount");
        q = _copy(p);
        q.capIn[0] = q.amountIn[0] - 1;
        _expectPoolOnly(abi.encode(q), false, true, amount, poolOnly, ms, "leg over its cap");
        q = _copy(p);
        q.capMin[0] = q.amountIn[0] + 1;
        _expectPoolOnly(abi.encode(q), false, true, amount, poolOnly, ms, "leg under its smallest fill");
        q = _copy(p);
        q.status[0] = 10;
        _expectPoolOnly(abi.encode(q), false, true, amount, poolOnly, ms, "bad status");
        q = _copy(p);
        q.amountIn[5] = 10 * USDC_1;
        q.capIn[5] = 10 * USDC_1;
        q.poolIn -= 10 * USDC_1;
        _expectPoolOnly(abi.encode(q), false, true, amount, poolOnly, ms, "leg for a slot that does not exist");
        q = _copy(p);
        q.amountIn[3] = 10 * USDC_1;
        q.capIn[3] = 10 * USDC_1;
        q.amountOut[3] = 1;
        q.poolIn -= 10 * USDC_1;
        _expectPoolOnly(abi.encode(q), false, true, amount, poolOnly, ms, "four legs");
        q = _copy(p);
        uint256 tiny = amount * 50 / 10_000 - 1;
        q.poolIn += q.amountIn[2] - tiny;
        q.amountIn[2] = tiny;
        q.capMin[2] = 0;
        _expectPoolOnly(abi.encode(q), false, true, amount, poolOnly, ms, "leg under MIN_LEG_BPS");
        q = _copy(p);
        q.poolOut = 0;
        _expectPoolOnly(abi.encode(q), false, true, amount, poolOnly, ms, "not better");
        q = _copy(p);
        q.truncated = 1;
        q.walked = q.poolIn - 1;
        _expectPoolOnly(abi.encode(q), false, true, amount, poolOnly, ms, "truncated past the walk");
        q = _copy(p);
        q.amountOut[0] = uint256(uint128(type(int128).max)) + 1;
        _expectPoolOnly(abi.encode(q), false, true, amount, poolOnly, ms, "output over int128");

        // The PoolManager's total (carry-over 7), MUMB in: the PoolManager holds only the pools' seed MUMB.
        uint256 pmMumb = mumb.balanceOf(address(manager));
        uint256 big = pmMumb + 1_000 * MUMB_1;
        q = _copy(_plan(keyV2, false, 100 * MUMB_1));
        for (uint256 i; i < 6; i++) {
            (q.amountIn[i], q.amountOut[i], q.capIn[i], q.capMin[i], q.status[i]) = (0, 0, 0, 0, LegStatus.SKIP_MIN_LEG);
        }
        q.amountIn[0] = pmMumb + 1;
        q.capIn[0] = pmMumb + 1;
        q.amountOut[0] = 1;
        q.status[0] = LegStatus.FILLED;
        q.poolIn = big - q.amountIn[0];
        q.poolOnlyOut = 0;
        q.tail = 0;
        q.truncated = 0;
        Run memory poolOnlyMumb = _poolOnly(keyV2, false, big);
        _expectPoolOnly(abi.encode(q), false, false, big, poolOnlyMumb, ms, "legs over the PoolManager's balance");
    }

    /// @dev A splitter that burns all its gas: the call is capped at PLAN_GAS_CAP, fails, and the swap is pool-only.
    function test_V207_splitterOutOfGasIsPoolOnly() public {
        _initExact(keyV2);
        M[] memory ms = _threeMakers();
        uint256 amount = 1_000 * USDC_1;
        Run memory po = _poolOnly(keyV2, true, amount);
        vm.etch(address(splitter), _burnerCode());
        Book memory b0 = _book(ms);
        Run memory r = _run(keyV2, true, amount, "");
        _assertBooks(b0, _book(ms), true, amount, r, ms);
        _expectAllStatus(r.legs, LegStatus.SKIP_PLAN, "out of gas");
        assertEq(r.got, po.got, "pool-only");
        console2.log("gas: pool-only swap", po.gasUsed);
        console2.log("gas: swap with a burning splitter", r.gasUsed);
        assertLe(r.gasUsed, po.gasUsed + hookV2.PLAN_GAS_CAP() + 100_000, "bounded by PLAN_GAS_CAP");
    }

    /// @dev A splitter that lies about the pool (D-35 accepts this gap: the hook does not re-read the pool). The
    ///      forged plan understates pool-only (so a worse split passes the comparison), routes most of the input to a
    ///      maker priced worse than the pool, and reports an inflated cap for another maker. What still holds: the
    ///      honest-cap leg fills exactly its planned amount, the over-cap leg is refused by the guard and settled
    ///      back, deltas net to zero, the hook holds nothing, and a router with the trader's minimum output (the
    ///      real pool-only output) reverts the swap.
    function test_V207_lyingSplitterBounded() public {
        _initExact(keyV2);
        StrategyTemplate.Params memory tight = _pf(FEE_005);
        tight.bandBps = 50;
        M[] memory ms = new M[](3);
        ms[0] = _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p()); // honest best
        ms[1] = _joinM(keyV2, makers[1], 100_000e18, 100_000e6, _pf(FEE_150)); // worse than the pool here
        ms[2] = _joinM(keyV2, makers[2], 2_000e18, 2_000e6, tight); // small band cap
        uint256 amount = 200 * USDC_1;
        Plan memory honest = _plan(keyV2, true, amount);
        assertEq(honest.amountIn[1], 0, "premise: the honest plan gives the worse maker nothing");
        uint256 overCap = honest.capIn[2] * 3 / 2;
        assertLt(honest.capIn[2], overCap, "premise");

        Plan memory q = _copy(honest);
        (q.amountIn[0], q.amountOut[0], q.status[0]) = (0, 0, LegStatus.SKIP_MIN_LEG);
        (uint256 x1, uint256 y1) = _virt(ms[1], true);
        q.amountIn[1] = 150 * USDC_1;
        q.amountOut[1] = _cpOut(x1, y1, FEE_150, q.amountIn[1]);
        (q.capMin[1], q.capIn[1], q.status[1]) = (0, q.amountIn[1], LegStatus.FILLED);
        (uint256 x2, uint256 y2) = _virt(ms[2], true);
        q.amountIn[2] = overCap;
        q.amountOut[2] = _cpOut(x2, y2, FEE_005, overCap);
        (q.capMin[2], q.capIn[2], q.status[2]) = (0, overCap, LegStatus.FILLED);
        q.poolIn = amount - q.amountIn[1] - q.amountIn[2];
        // The lie: pool-only understated (a pool quote above int128 max would be refused by the hook's bounds).
        (q.poolOnlyOut, q.tail, q.truncated) = (0, 0, 0);

        // Premise: the guard itself refuses the over-cap leg.
        {
            uint256 s0 = vm.snapshotState();
            ISwapVM.Order memory o2 = _order(keyV2, ms[2]); // built first: `_order` makes an external call
            bytes memory td2 = _td(q.amountOut[2]);
            deal(USDC, address(hookV2), overCap);
            vm.startPrank(address(hookV2));
            IERC20(USDC).approve(ROUTER, overCap);
            vm.expectPartialRevert(BandExceeded.selector);
            ISwapVM(ROUTER).swap(o2, USDC, address(mumb), overCap, td2);
            vm.stopPrank();
            vm.revertToState(s0);
        }

        uint256 poolOnly = _poolOnly(keyV2, true, amount).got;
        vm.mockCall(address(splitter), abi.encodeWithSelector(ConfluenceSplitter.planExactIn.selector), abi.encode(q));
        uint256 s = vm.snapshotState();
        Book memory b0 = _book(ms);
        Run memory r = _run(keyV2, true, amount, "");
        _assertBooks(b0, _book(ms), true, amount, r, ms);
        _assertClean();
        assertEq(r.legs[1].status, LegStatus.FILLED, "the lying plan's leg fills");
        assertEq(r.legs[1].amountIn, q.amountIn[1], "exactly its planned amount");
        assertEq(r.legs[1].amountOut, q.amountOut[1], "exactly its planned output");
        assertEq(r.legs[2].status, LegStatus.SKIP_REVERT, "the over-cap leg is refused by the guard");
        assertLt(r.got, poolOnly, "the gap D-35 accepts: worse than pool-only");
        console2.log("lying splitter: realised", r.got, "pool-only", poolOnly);
        vm.revertToState(s);

        // The trader's slippage limit catches it.
        MinOutRouter mr = new MinOutRouter(swapRouter);
        vm.startPrank(trader);
        IERC20(USDC).approve(address(mr), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(MinOutRouter.TooLittleReceived.selector, poolOnly, r.got));
        mr.swapExactIn(keyV2, true, amount, poolOnly);
        vm.stopPrank();
    }

    // =====================================================================================================
    // Carry-over 7 and gas
    // =====================================================================================================

    /// @dev MUMB in. The PoolManager holds only the pools' MUMB; three deep makers want more than that in total. The
    ///      legs, largest first, are trimmed to the PoolManager's balance, the rest go to the pool, the swap succeeds
    ///      and is no worse than pool-only.
    function test_V207_poolManagerTotalCap() public {
        _initExact(keyV2);
        _addFullRange(keyV2, 10_000e6, 10_000e18);
        M[] memory ms = new M[](3);
        for (uint256 i; i < 3; i++) {
            ms[i] = _joinM(keyV2, makers[i], 400_000e18, 400_000e6, _pf(FEE_005));
        }
        uint256 amount = 40_000 * MUMB_1;
        uint256 pmMumb = mumb.balanceOf(address(manager));
        Plan memory p = _plan(keyV2, false, amount);
        uint256 capSum = p.capIn[0] + p.capIn[1] + p.capIn[2];
        assertGt(capSum, pmMumb, "premise: the makers' caps add up to more than the PoolManager holds");
        uint256 poolOnly = _poolOnly(keyV2, false, amount).got;
        Book memory b0 = _book(ms);
        Run memory r = _run(keyV2, false, amount, "");
        _assertBooks(b0, _book(ms), false, amount, r, ms);
        (uint256 sumIn,) = _sumLegs(r.legs);
        assertLe(sumIn, pmMumb, "legs within the PoolManager's balance");
        assertEq(sumIn, pmMumb, "trimmed to exactly the balance");
        assertGe(r.got, poolOnly, "never worse");
        console2.log("PoolManager MUMB", pmMumb, "legs", sumIn);
    }

    /// @dev `MAX_LEGS` and the re-solve. Four makers whose first-solve shares all qualify (each at least its
    ///      `capMin` and `MIN_LEG_BPS`): the smallest share is dropped (`SKIP_MIN_LEG`), and the three kept get exactly
    ///      a fresh `SplitMath` solve over the pool and those three, each at least its first-solve share. The swap
    ///      then fills exactly those legs.
    function test_V207_maxLegsKeepsLargestAndResolves() public {
        _initExact(keyV2);
        M[] memory three = _threeMakers();
        M[] memory ms = new M[](4);
        for (uint256 j; j < 3; j++) {
            ms[j] = three[j];
        }
        ms[3] = _joinM(keyV2, makers[3], 40_000e18, 40_000e6, _p());
        uint256 amount = 2_000 * USDC_1;

        (int24 sn, int56 e,) = hookV2.anchorOfX(idV2);
        PoolVenue.Pool memory pool = PoolVenue.read(manager, idV2, keyV2.tickSpacing, true, _lim(true));
        MakerVenue.Maker[] memory mk = MakerVenue.read(
            manager, keyV2, _guard(), IConfluenceHookView(address(hookV2)).strategiesOf(idV2), true, sn, e
        );
        SplitMath.Venue[] memory pv = PoolVenue.venues(pool, true);
        (SplitMath.Venue[] memory mv,) = MakerVenue.toVenues(mk);
        assertEq(mv.length, 4, "premise: four live makers");
        (uint256[] memory a4,) = SplitMath.solveExactIn(pv, mv, amount);
        uint256 smallest;
        for (uint256 j; j < 4; j++) {
            assertGe(a4[j + 1], mk[j].capMin, "premise: every first-solve share is at least its capMin");
            assertGe(a4[j + 1] * 10_000, amount * hookV2.MIN_LEG_BPS(), "premise: every share is at least 0.5%");
            if (a4[j + 1] < a4[smallest + 1]) smallest = j;
        }

        SplitMath.Venue[] memory mv3 = new SplitMath.Venue[](3);
        uint256[3] memory kept;
        uint256 k;
        for (uint256 j; j < 4; j++) {
            if (j == smallest) continue;
            (mv3[k], kept[k]) = (mv[j], j);
            k++;
        }
        (uint256[] memory a3,) = SplitMath.solveExactIn(pv, mv3, amount);

        Plan memory p = _plan(keyV2, true, amount);
        assertEq(p.status[smallest], LegStatus.SKIP_MIN_LEG, "the smallest share is dropped");
        assertEq(p.amountIn[smallest], 0, "dropped: no input");
        for (uint256 j; j < 3; j++) {
            uint256 i = kept[j];
            assertEq(p.status[i], LegStatus.FILLED, "kept");
            assertEq(p.amountIn[i], a3[j + 1], "kept leg = the re-solve over the three");
            assertGe(a3[j + 1], a4[i + 1], "a kept share only grows");
        }

        Book memory b0 = _book(ms);
        Run memory r = _run(keyV2, true, amount, "");
        _assertBooks(b0, _book(ms), true, amount, r, ms);
        for (uint256 j; j < 4; j++) {
            assertEq(r.legs[j].amountIn, p.amountIn[j], "the swap fills the plan");
            assertEq(r.legs[j].status, uint8(p.status[j]), "the swap reports the plan's codes");
        }
        console2.log("dropped maker slot", smallest, "first-solve share", a4[smallest + 1]);
    }

    /// @dev Full-swap gas (through PoolSwapTest, every touched account cooled first) for pool-only and 1, 3 and 6
    ///      makers, next to v1's hinted swap. No ceilings (V2-11). Swaps above 1,000,000 gas are flagged.
    function test_V207_gasLog() public {
        _initExact(keyV2);
        uint256 s = vm.snapshotState();
        uint256 g0 = _coldRun(keyV2, true, 1_000 * USDC_1).gasUsed;
        M[] memory one = new M[](1);
        one[0] = _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
        uint256 g1 = _coldRun(keyV2, true, 1_000 * USDC_1).gasUsed;
        vm.revertToState(s);
        _threeMakers();
        uint256 g3 = _coldRun(keyV2, true, 1_000 * USDC_1).gasUsed;
        _joinM(keyV2, makers[3], 50_000e18, 50_000e6, _p());
        _joinM(keyV2, makers[4], 1_000e18, 1_000e6, _p());
        _joinM(keyV2, makers[5], 30_000e18, 30_000e6, _pf(FEE_100));
        Run memory r6 = _coldRun(keyV2, true, 1_000 * USDC_1);
        uint256 g6 = r6.gasUsed;
        assertEq(_countStatus(r6.legs, LegStatus.FILLED), 3, "six makers: three legs");
        assertEq(_countStatus(r6.legs, LegStatus.SKIP_MIN_LEG), 3, "the rest SKIP_MIN_LEG");
        assertEq(r6.legs[4].status, LegStatus.SKIP_MIN_LEG, "the 1,000-deep maker (under 0.5%) is dropped");
        vm.revertToState(s);
        uint256 gV1 = _v1HintedGas();
        console2.log("gas: v1 hinted swap (hint 550,000,000)", gV1);
        _logGas("gas: pool-only (no makers)", g0);
        _logGas("gas: 1 maker", g1);
        _logGas("gas: 3 makers", g3);
        _logGas("gas: 6 makers", g6);
    }
}

/// @notice V2-07 on Unichain (named risk 5): an ordinary router swap with empty `hookData` fills an exclusive maker
///         through the hook (the hook is the real taker: take, approve, router, reset, settle, delta), and the same
///         strategy refuses an outside taker.
contract V207UnichainTest is UnichainBase, V207Helpers {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant SHIPPED = 100_000e18;
    uint256 internal constant SWAP_IN = 1e17;

    function test_V207_exclusiveTakerFillsThroughHook() public {
        StrategyTemplate.Params memory p =
            StrategyTemplate.Params({feeE9: FEE_0_30_PCT, bandBps: 200, driftTicks: 300, exclusive: true, salt: 0});
        ISwapVM.Order memory order =
            StrategyTemplate.order(maker, StrategyTemplate.program(p, manager, key, address(hook.bandGuard())));
        t0.mint(maker, SHIPPED);
        t1.mint(maker, SHIPPED);
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(t0), address(t1));
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (SHIPPED, SHIPPED);
        vm.startPrank(maker);
        t0.approve(AQUA_ADDR, type(uint256).max);
        t1.approve(AQUA_ADDR, type(uint256).max);
        bytes32 h = IAqua(AQUA_ADDR).ship(ROUTER_ADDR, abi.encode(order), tokens, amounts);
        hook.register(key, p);
        vm.stopPrank();

        address trader = makeAddr("trader");
        t0.mint(trader, SWAP_IN);
        PoolSwapTest sr = new PoolSwapTest(manager);
        vm.prank(trader);
        t0.approve(address(sr), type(uint256).max);
        assertLe(SWAP_IN, t0.balanceOf(address(manager)), "premise: the PoolManager holds the input");

        // Pool-only from the same state, for the never-worse comparison.
        uint256 s = vm.snapshotState();
        vm.prank(maker);
        hook.unregister(key);
        uint256 poolOnly = _swapOut(sr, trader);
        vm.revertToState(s);

        uint256[2] memory pm0 = [t0.balanceOf(address(manager)), t1.balanceOf(address(manager))];
        vm.recordLogs();
        uint256 got = _swapOut(sr, trader);
        (ConfluenceHook.Leg[] memory legs,) = _legsFrom(vm.getRecordedLogs(), address(hook));
        assertEq(legs.length, 1, "one slot");
        assertEq(legs[0].status, LegStatus.FILLED, "filled through the hook");
        uint256 a = legs[0].amountIn;
        uint256 b = legs[0].amountOut;
        assertGt(a, 0, "a leg");
        assertEq(b, _cpOut(SHIPPED, SHIPPED, FEE_0_30_PCT, a), "SwapVM's quote");
        assertEq(t0.balanceOf(trader), 0, "trader paid the whole input");
        assertEq(t0.balanceOf(maker), SHIPPED + a, "maker wallet in");
        assertEq(t1.balanceOf(maker), SHIPPED - b, "maker wallet out");
        (uint256 v0,) = IAqua(AQUA_ADDR).rawBalances(maker, ROUTER_ADDR, h, address(t0));
        (uint256 v1,) = IAqua(AQUA_ADDR).rawBalances(maker, ROUTER_ADDR, h, address(t1));
        assertEq(v0, SHIPPED + a, "Aqua in");
        assertEq(v1, SHIPPED - b, "Aqua out");
        assertEq(t0.balanceOf(address(manager)), pm0[0] + SWAP_IN - a, "PoolManager kept the pool's share");
        assertEq(got, b + (pm0[1] - t1.balanceOf(address(manager))), "trader got the leg and the pool leg");
        assertEq(t0.balanceOf(address(hook)) + t1.balanceOf(address(hook)), 0, "hook holds nothing");
        assertEq(t0.allowance(address(hook), ROUTER_ADDR), 0, "approval reset");
        assertGe(got, poolOnly, "never worse");

        // Any other taker is refused by the guard's exclusive rule.
        address stranger = makeAddr("stranger");
        t0.mint(stranger, SWAP_IN);
        vm.startPrank(stranger);
        t0.approve(ROUTER_ADDR, SWAP_IN);
        vm.expectRevert(abi.encodeWithSelector(TakerNotHook.selector, stranger));
        ISwapVM(ROUTER_ADDR).swap(order, address(t0), address(t1), SWAP_IN, _takerDataFor(stranger));
        vm.stopPrank();
    }

    function _swapOut(PoolSwapTest sr, address trader) internal returns (uint256 got) {
        uint256 before = t1.balanceOf(trader);
        vm.prank(trader);
        sr.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(SWAP_IN), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        got = t1.balanceOf(trader) - before;
    }
}
