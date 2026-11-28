// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {LegStatus, Plan} from "../../src/ConfluenceSplitter.sol";
import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {ConfluenceLens} from "../../src/ConfluenceLens.sol";
import {MakerVenue} from "../../src/libraries/MakerVenue.sol";
import {PlanCheck} from "../../src/libraries/PlanCheck.sol";
import {PoolVenue} from "../../src/libraries/PoolVenue.sol";
import {SplitBase} from "../base/SplitBase.t.sol";

/// @notice V2-11 gas measurements, one method for every number (M11). Logs only: the ceilings and the snapshot
///         scenarios are added after the levers are ranked.
/// @dev M11: every measurement starts from one `vm.snapshotState()` of the same fixture, moves to the next block (so
///      the swap is the block's first and runs the anchor update), cools every account the swap touches (the manager,
///      the hook, both splitters, Aqua, the router, USDC and its implementation, MUMB, the guard, all six makers, the
///      trader and the swap router), and takes `gasleft()` around the swap through `PoolSwapTest`. It differs from
///      V2-07's `gasLog` (no revert between rows, no anchor update in later rows), V2-09's and V2-10's tables
///      (V2-10's cools only the splitter of the mode it measures and has no 6-maker row), and none of them cooled the
///      USDC implementation, the trader or the swap router.
contract V211GasTest is SplitBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant USDC_IMPL = 0x43506849D7C04F9138D1A2050bbF3A0c054402dd;
    uint256 internal constant EXACT_IN_USDC = 1_000e6;
    uint256 internal constant EXACT_IN_MUMB = 1_000e18;
    uint256 internal constant EXACT_OUT_MUMB = 990e18;
    uint256 internal constant EXACT_OUT_USDC = 990e6;

    uint256 internal bn0;
    uint256 internal ts0;

    // ------------------------------------------------------------------------------------------ M11

    function _coolAll() internal {
        address[10] memory t = [
            address(manager),
            address(hookV2),
            address(splitter),
            address(splitterOut),
            AQUA,
            ROUTER,
            USDC,
            USDC_IMPL,
            address(mumb),
            _guard()
        ];
        for (uint256 i; i < t.length; i++) {
            vm.cool(t[i]);
        }
        for (uint256 i; i < 6; i++) {
            vm.cool(makers[i]);
        }
        vm.cool(trader);
        vm.cool(address(swapRouter));
    }

    function _nextBlockM11() internal {
        vm.roll(bn0 + 1);
        vm.warp(ts0 + 12);
    }

    /// @dev One M11 swap on `k`; returns the gas and the number of FILLED legs.
    function _m11(PoolKey memory k, bool zfo, bool exactIn, uint256 amount)
        internal
        returns (uint256 used, uint256 filled)
    {
        _nextBlockM11();
        _coolAll();
        vm.recordLogs();
        uint256 g = gasleft();
        _swap(k, trader, zfo, exactIn ? -int256(amount) : int256(amount), "");
        used = g - gasleft();
        (ConfluenceHook.Leg[] memory legs,) = _legsFrom(vm.getRecordedLogs(), address(hookV2));
        filled = _countStatus(legs, 0);
    }

    function _amount(bool zfo, bool exactIn) internal pure returns (uint256) {
        if (exactIn) return zfo ? EXACT_IN_USDC : EXACT_IN_MUMB;
        return zfo ? EXACT_OUT_MUMB : EXACT_OUT_USDC;
    }

    /// @dev Registers `n` makers (0, 1, 3 or 6) on `keyV2` as V2-07's `gasLog` does.
    function _makers(uint256 n) internal {
        if (n == 1) {
            _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
        } else if (n >= 3) {
            _threeMakers();
            if (n == 6) {
                _joinM(keyV2, makers[3], 50_000e18, 50_000e6, _p());
                _joinM(keyV2, makers[4], 1_000e18, 1_000e6, _p());
                _joinM(keyV2, makers[5], 30_000e18, 30_000e6, _pf(FEE_100));
            }
        }
    }

    /// @dev A hookless pool with the same fee, spacing, price and liquidity as `keyV2`: the floor.
    function _plainPool() internal returns (PoolKey memory k) {
        k = PoolKey({
            currency0: keyV2.currency0,
            currency1: keyV2.currency1,
            fee: keyV2.fee,
            tickSpacing: keyV2.tickSpacing,
            hooks: IHooks(address(0))
        });
        manager.initialize(k, anchorSqrtPriceX96(true));
        deal(USDC, deployer, IERC20(USDC).balanceOf(deployer) + 1e15);
        vm.startPrank(deployer);
        mumb.mint(deployer, 1e27);
        IERC20(USDC).approve(address(liquidityRouter), type(uint256).max);
        mumb.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(manager.getLiquidity(idV2))),
                salt: bytes32(0)
            }),
            ""
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------ the table

    /// @dev Full swaps: the hookless floor, then 0, 1, 3 and 6 makers, exact in and out, both directions.
    function test_V211_gasTable() public {
        _initExact(keyV2);
        bn0 = block.number;
        ts0 = block.timestamp;
        PoolKey memory plain = _plainPool();
        uint256 base = vm.snapshotState();
        uint8[4] memory ns = [0, 1, 3, 6];

        console2.log("M11 full swaps: label | gas | filled legs");
        for (uint256 d; d < 2; d++) {
            bool zfo = d == 0;
            for (uint256 m; m < 2; m++) {
                bool exactIn = m == 0;
                uint256 amt = _amount(zfo, exactIn);
                string memory tag = string.concat(zfo ? "USDC in " : "MUMB in ", exactIn ? "exact-in  " : "exact-out ");
                vm.revertToState(base);
                (uint256 gp,) = _m11(plain, zfo, exactIn, amt);
                console2.log(string.concat(tag, "hookless floor"), gp);
                for (uint256 i; i < ns.length; i++) {
                    vm.revertToState(base);
                    _makers(ns[i]);
                    (uint256 g, uint256 f) = _m11(keyV2, zfo, exactIn, amt);
                    console2.log(string.concat(tag, vm.toString(uint256(ns[i])), " makers"), g, f);
                }
            }
        }
    }

    /// @dev One cold plan call per splitter (the hook's call without the hook), 1, 3 and 6 makers.
    function test_V211_planGas() public {
        _initExact(keyV2);
        bn0 = block.number;
        ts0 = block.timestamp;
        uint256 base = vm.snapshotState();
        uint8[3] memory ns = [1, 3, 6];
        console2.log("M11 plan gas (cold, direct call): label | gas");
        for (uint256 i; i < ns.length; i++) {
            vm.revertToState(base);
            _makers(ns[i]);
            for (uint256 m; m < 2; m++) {
                bool exactIn = m == 0;
                _nextBlockM11();
                (int24 snap, int56 emaX,) = hookV2.anchorOfX(idV2);
                _coolAll();
                uint256 g = gasleft();
                if (exactIn) {
                    splitter.planExactIn(keyV2, true, TickMath.MIN_SQRT_PRICE + 1, EXACT_IN_USDC, snap, emaX);
                } else {
                    splitterOut.planExactOut(keyV2, true, TickMath.MIN_SQRT_PRICE + 1, EXACT_OUT_MUMB, snap, emaX);
                }
                g -= gasleft();
                console2.log(
                    string.concat(exactIn ? "planExactIn  " : "planExactOut ", vm.toString(uint256(ns[i])), " makers"),
                    g
                );
            }
        }
    }

    /// @dev `MakerVenue.read` / `readOut` and `PoolVenue.read`, called inline (internal libraries: no harness).
    function test_V211_readGas() public {
        _initExact(keyV2);
        bn0 = block.number;
        ts0 = block.timestamp;
        uint256 base = vm.snapshotState();
        uint8[3] memory ns = [1, 3, 6];
        console2.log("M11 library reads (cold, inline): label | gas");
        for (uint256 i; i < ns.length; i++) {
            vm.revertToState(base);
            _makers(ns[i]);
            _nextBlockM11();
            (int24 snap, int56 emaX,) = hookV2.anchorOfX(idV2);
            ConfluenceHook.Slot[] memory s = hookV2.strategiesOf(idV2);
            MakerVenue.Entry[] memory e = new MakerVenue.Entry[](s.length);
            for (uint256 j; j < s.length; j++) {
                e[j] = MakerVenue.Entry({maker: s[j].maker, params: s[j].params, strategyHash: s[j].strategyHash});
            }
            _coolAll();
            uint256 g = gasleft();
            MakerVenue.read(manager, keyV2, _guard(), e, true, snap, emaX);
            g -= gasleft();
            console2.log(string.concat("MakerVenue.read    ", vm.toString(uint256(ns[i])), " makers"), g);
            _coolAll();
            g = gasleft();
            MakerVenue.readOut(manager, keyV2, _guard(), e, true, snap, emaX);
            g -= gasleft();
            console2.log(string.concat("MakerVenue.readOut ", vm.toString(uint256(ns[i])), " makers"), g);
        }
        _poolReadGas(keyV2, "PoolVenue.read v1 pool (1 range, end of liquidity)");
        PoolKey memory gap = _gapKey();
        _poolReadGas(gap, "PoolVenue.read 8-segment gapped pool");
    }

    function _poolReadGas(PoolKey memory k, string memory label) internal {
        _coolAll();
        uint256 g = gasleft();
        PoolVenue.Pool memory p = PoolVenue.read(manager, k.toId(), k.tickSpacing, true, TickMath.MIN_SQRT_PRICE + 1);
        g -= gasleft();
        console2.log(label, g, p.segments.length);
    }

    // ------------------------------------------------------------------------------------------ scenarios

    uint256 internal constant SMALL = 0;
    uint256 internal constant MID = 1;
    uint256 internal constant LARGE = 2;

    /// @dev `legs` makers of equal fee (0.30%) and depth 100,000 / 80,000 / 60,000 on `k`: every maker takes a share at
    ///      every size, so the leg count is the maker count.
    function _gasMakers(PoolKey memory k, uint256 legs) internal {
        uint256[3] memory depth = [uint256(100_000), 80_000, 60_000];
        for (uint256 i; i < legs; i++) {
            _joinM(k, makers[i], depth[i] * 1e18, depth[i] * 1e6, _p());
        }
    }

    /// @dev Amount per size class, in units of the swap's specified token (USDC in, or MUMB out).
    function _scn(uint256 size, bool exactIn, uint256 legs) internal pure returns (uint256) {
        if (exactIn) return [uint256(100), 1_000, legs == 0 ? 960 : 2_500][size] * 1e6;
        return [uint256(100), 250, 400][size] * 1e18;
    }

    /// @dev The scenario on the gapped pool (ticks inside the swap's reach), fixture built with gas metering paused,
    ///      the swap measured as M11. Asserts every maker filled. Returns the gas, the crossings of the pool's tick.
    function _scenario(uint256 legs, uint256 size, bool exactIn) internal returns (uint256 gas_, uint256 crossed) {
        vm.pauseGasMetering();
        PoolKey memory gap = _gapKey();
        _initExact(gap);
        bn0 = block.number;
        ts0 = block.timestamp;
        _gasMakers(gap, legs);
        vm.resumeGasMetering();
        uint256 filled;
        (gas_, filled) = _m11(gap, true, exactIn, _scn(size, exactIn, legs));
        assertEq(filled, legs, "every maker fills");
        crossed = _crossed(gap);
    }

    /// @dev Initialised ticks of the gapped pool crossed by the pool's tick (zero for one: C-60 to C-420).
    function _crossed(PoolKey memory k) internal view returns (uint256 n) {
        int24 c = _floorToSpacing(TickMath.getTickAtSqrtPrice(anchorSqrtPriceX96(true)));
        (, int24 t,,) = manager.getSlot0(k.toId());
        for (uint256 j = 1; j <= 7; j++) {
            if (t < c - int24(int256(60 * j))) n++;
        }
    }

    function test_V211_scenarioTable() public {
        console2.log("M11 scenarios: legs / size / mode | gas | crossings");
        for (uint256 l; l <= 3; l++) {
            for (uint256 z; z < 3; z++) {
                for (uint256 m; m < 2; m++) {
                    uint256 s = vm.snapshotState();
                    (uint256 g, uint256 c) = _scenario(l, z, m == 0);
                    console2.log(
                        string.concat(vm.toString(l), "L size", vm.toString(z), m == 0 ? " in " : " out "), g, c
                    );
                    vm.revertToState(s);
                }
            }
        }
    }

    function test_V211_snap_0L_small_in() public {
        _scenario(0, 0, true);
    }

    function test_V211_snap_0L_small_out() public {
        _scenario(0, 0, false);
    }

    function test_V211_snap_0L_mid_in() public {
        _scenario(0, 1, true);
    }

    function test_V211_snap_0L_mid_out() public {
        _scenario(0, 1, false);
    }

    function test_V211_snap_0L_large_in() public {
        _scenario(0, 2, true);
    }

    function test_V211_snap_0L_large_out() public {
        _scenario(0, 2, false);
    }

    function test_V211_snap_1L_small_in() public {
        _scenario(1, 0, true);
    }

    function test_V211_snap_1L_small_out() public {
        _scenario(1, 0, false);
    }

    function test_V211_snap_1L_mid_in() public {
        _scenario(1, 1, true);
    }

    function test_V211_snap_1L_mid_out() public {
        _scenario(1, 1, false);
    }

    function test_V211_snap_1L_large_in() public {
        _scenario(1, 2, true);
    }

    function test_V211_snap_1L_large_out() public {
        _scenario(1, 2, false);
    }

    function test_V211_snap_2L_small_in() public {
        _scenario(2, 0, true);
    }

    function test_V211_snap_2L_small_out() public {
        _scenario(2, 0, false);
    }

    function test_V211_snap_2L_mid_in() public {
        _scenario(2, 1, true);
    }

    function test_V211_snap_2L_mid_out() public {
        _scenario(2, 1, false);
    }

    function test_V211_snap_2L_large_in() public {
        _scenario(2, 2, true);
    }

    function test_V211_snap_2L_large_out() public {
        _scenario(2, 2, false);
    }

    function test_V211_snap_3L_small_in() public {
        _scenario(3, 0, true);
    }

    function test_V211_snap_3L_small_out() public {
        _scenario(3, 0, false);
    }

    function test_V211_snap_3L_mid_in() public {
        _scenario(3, 1, true);
    }

    function test_V211_snap_3L_mid_out() public {
        _scenario(3, 1, false);
    }

    function test_V211_snap_3L_large_in() public {
        _scenario(3, 2, true);
    }

    function test_V211_snap_3L_large_out() public {
        _scenario(3, 2, false);
    }

    // ------------------------------------------------------------------------------------------ never reverts

    uint256 internal constant V_LEGIT = 0;
    uint256 internal constant V_BURN_GUARD = 1;
    uint256 internal constant V_BURN_SPLITTER = 2;
    uint256 internal constant FIXTURES = 4;

    /// @dev Report mode: a reverting hooked swap is counted instead of failing the test. (Counters are memory values:
    ///      `vm.revertToState` rolls this contract's storage back too.)
    bool internal report;

    /// @dev The gas limits: 285,000 to 500,000 step 5,000 (44), 550,000 to 1,000,000 step 50,000 (10), 1,100,000 to
    ///      3,000,000 step 100,000 (20), then 3,500,000, 4,000,000, 5,000,000 and 6,000,000: 78 limits.
    function _limits() internal pure returns (uint256[] memory l) {
        l = new uint256[](78);
        uint256 n;
        for (uint256 g = 285_000; g <= 500_000; g += 5_000) {
            l[n++] = g;
        }
        for (uint256 g = 550_000; g <= 1_000_000; g += 50_000) {
            l[n++] = g;
        }
        for (uint256 g = 1_100_000; g <= 3_000_000; g += 100_000) {
            l[n++] = g;
        }
        l[n++] = 3_500_000;
        l[n++] = 4_000_000;
        l[n++] = 5_000_000;
        l[n++] = 6_000_000;
    }

    /// @dev Fixture `id`: 0 = gapped pool, 1 maker, 1,000 USDC; 1 = gapped, 3 makers, 2,500 USDC (pool crosses ticks);
    ///      2 = gapped, 3 makers, 100 USDC; 3 = the v1 pool, 6 makers, 1,000 USDC. Exact output: the same size in MUMB
    ///      times 0.99. Returns the pool and the amount, with the next block reached (the anchor update runs).
    function _fixture(uint256 id, bool exactIn) internal returns (PoolKey memory k, uint256 amount) {
        if (id == 3) {
            k = keyV2;
            _initExact(k);
            _makers(6);
            amount = _amount(true, exactIn);
        } else {
            k = _gapKey();
            _initExact(k);
            _gasMakers(k, id == 0 ? 1 : 3);
            uint256 usdc = id == 0 ? 1_000 : (id == 1 ? 2_500 : 100);
            amount = exactIn ? usdc * 1e6 : (usdc * 99 / 100) * 1e18;
        }
        _nextBlock(12);
    }

    function _tryAtLimit(PoolKey memory k, uint256 limit, bool exactIn, uint256 amount) internal returns (bool ok) {
        vm.startPrank(trader);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        mumb.approve(address(swapRouter), type(uint256).max);
        try swapRouter.swap{gas: limit}(
            k,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: exactIn ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: _lim(true)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            ok = true;
        } catch {
            ok = false;
        }
        vm.stopPrank();
    }

    /// @dev The window left open on the fixture whose pool-only path does not fit the walk bound (fixture 1: the pool
    ///      crosses more ticks than `MAX_TICK_STEPS`, so the walk is truncated and the reserve is the stated maximum, which
    ///      is below the pool's real need of about 1.31M). Measured on the committed design; pinned so a widening fails:
    ///      at most `count` failing limits, all within `[lo, hi]`. Every other fixture has no window at all.
    struct Pin {
        uint256 count;
        uint256 lo;
        uint256 hi;
    }

    function _pin(uint256 variant, uint256 id, bool exactIn) internal pure returns (Pin memory) {
        if (id != 1) return Pin(0, 0, 0);
        if (!exactIn) return Pin(2, 1_500_000, 1_600_000);
        if (variant == V_LEGIT) return Pin(3, 1_500_000, 1_700_000);
        if (variant == V_BURN_GUARD) return Pin(12, 1_500_000, 3_000_000);
        return Pin(14, 1_500_000, 2_800_000);
    }

    /// @dev At every limit where the pool-only swap passes (same hooked pool, legs skipped), the hooked swap passes and
    ///      the hook ends clean; the pinned window is the one allowed exception.
    function _sweep(PoolKey memory k, bool exactIn, uint256 amount, string memory label, Pin memory pin)
        internal
        returns (uint256 checked, uint256 filled, uint256 failures, uint256 maxFailLimit, uint256 minFailLimit)
    {
        uint256[] memory limits = _limits();
        minFailLimit = type(uint256).max;
        for (uint256 i; i < limits.length; i++) {
            uint256 s = vm.snapshotState();
            _skipLegs();
            bool poolOk = _tryAtLimit(k, limits[i], exactIn, amount);
            vm.revertToState(s);
            if (!poolOk) continue;
            checked++;
            vm.recordLogs();
            bool ok = _tryAtLimit(k, limits[i], exactIn, amount);
            if (!ok && (report || pin.count > 0)) {
                failures++;
                maxFailLimit = limits[i];
                if (limits[i] < minFailLimit) minFailLimit = limits[i];
                vm.getRecordedLogs();
                vm.revertToState(s);
                continue;
            }
            assertTrue(ok, string.concat(label, ": hooked swap reverted at gas limit ", vm.toString(limits[i])));
            (ConfluenceHook.Leg[] memory legs,) = _legsFrom(vm.getRecordedLogs(), address(hookV2));
            if (_countStatus(legs, LegStatus.FILLED) > 0) filled++;
            _assertClean();
            vm.revertToState(s);
        }
        assertGe(checked, 15, string.concat(label, ": the pool alone passes at enough limits"));
        if (!report && pin.count > 0) {
            assertLe(failures, pin.count, string.concat(label, ": the failing window widened (count)"));
            if (failures > 0) {
                assertGe(minFailLimit, pin.lo, string.concat(label, ": the failing window widened (low end)"));
                assertLe(maxFailLimit, pin.hi, string.concat(label, ": the failing window widened (high end)"));
            }
        }
    }

    function _sweepAll(uint256 variant) internal {
        uint256 base = vm.snapshotState();
        for (uint256 id; id < FIXTURES; id++) {
            for (uint256 m; m < 2; m++) {
                bool exactIn = m == 0;
                vm.revertToState(base);
                (PoolKey memory k, uint256 amount) = _fixture(id, exactIn);
                if (variant == V_BURN_GUARD) {
                    vm.etch(_guard(), _burnerCode());
                } else if (variant == V_BURN_SPLITTER) {
                    vm.etch(address(splitter), _burnerCode());
                    vm.etch(address(splitterOut), _burnerCode());
                }
                string memory label = string.concat(
                    "fixture ", vm.toString(id), exactIn ? " exact-in" : " exact-out", " variant ", vm.toString(variant)
                );
                (uint256 checked, uint256 filled, uint256 failures, uint256 hi, uint256 lo) =
                    _sweep(k, exactIn, amount, label, _pin(variant, id, exactIn));
                console2.log(label, checked, filled);
                if (report) console2.log("   failing limits / lowest / highest", failures, failures == 0 ? 0 : lo, hi);
            }
        }
    }

    function test_V211_neverRevertsWherePoolOnlyPasses_legit() public {
        _sweepAll(V_LEGIT);
    }

    function test_V211_neverRevertsWherePoolOnlyPasses_burningGuard() public {
        _sweepAll(V_BURN_GUARD);
    }

    function test_V211_neverRevertsWherePoolOnlyPasses_burningSplitter() public {
        _sweepAll(V_BURN_SPLITTER);
    }

    /// @dev Not acceptance tests: the same sweeps in report mode, so every failing limit is counted (one test per
    ///      variant: the three together exceed the test gas limit).
    function test_V211_sweepReport_legit() public {
        report = true;
        _sweepAll(V_LEGIT);
    }

    function test_V211_sweepReport_burningGuard() public {
        report = true;
        _sweepAll(V_BURN_GUARD);
    }

    function test_V211_sweepReport_burningSplitter() public {
        report = true;
        _sweepAll(V_BURN_SPLITTER);
    }

    // ------------------------------------------------------------------------------------------ lever 1: the walk

    function _eq(PoolVenue.Segment memory a, PoolVenue.Segment memory b) internal pure returns (bool) {
        return a.sqrtPriceStartX96 == b.sqrtPriceStartX96 && a.sqrtPriceEndX96 == b.sqrtPriceEndX96
            && a.liquidity == b.liquidity && a.x == b.x && a.y == b.y && a.capIn == b.capIn && a.capOut == b.capOut;
    }

    /// @dev The bounded walk is the unbounded walk cut after the first segment that covers the amount: the same
    ///      segments, not truncated, the step count equal to the segments here (no empty steps on this pool).
    function _checkBounded(PoolKey memory k, bool exactIn, uint256 amount, uint256 expectSegments) internal view {
        PoolVenue.Pool memory full = PoolVenue.read(manager, k.toId(), k.tickSpacing, true, _lim(true));
        PoolVenue.Pool memory cut =
            PoolVenue.readTo(manager, k.toId(), k.tickSpacing, true, _lim(true), amount, exactIn);
        assertEq(cut.segments.length, expectSegments, "segments walked");
        assertFalse(cut.truncated, "a walk that covered the amount is not truncated");
        uint256 sum;
        for (uint256 i; i < cut.segments.length; i++) {
            assertTrue(_eq(cut.segments[i], full.segments[i]), "same segment as the unbounded walk");
            sum += exactIn ? cut.segments[i].capIn : cut.segments[i].capOut;
            if (i + 1 < cut.segments.length) {
                assertLt(sum, amount, "a segment before the last did not cover the amount");
            }
        }
        assertGe(sum, amount, "the walked segments cover the amount");
        assertLe(cut.steps, full.steps, "no more steps than the unbounded walk");
    }

    function test_V211_walkStopsOnceTheAmountIsCovered() public {
        PoolKey memory gap = _gapKey();
        _checkBounded(gap, true, 100e6, 1);
        _checkBounded(gap, true, 400e6, 3);
        _checkBounded(gap, false, 100e18, 1);
        _checkBounded(gap, false, 400e18, 3);
        // the v1 pool: one range holds the whole trade
        _checkBounded(keyV2, true, 1_000e6, 1);
        _checkBounded(keyV2, false, 990e18, 1);
    }

    /// @dev An amount the pool cannot cover walks to its bound exactly as before, and is truncated there.
    function test_V211_walkPastTheLiquidityIsTheUnboundedWalk() public {
        PoolKey memory gap = _gapKey();
        PoolVenue.Pool memory full = PoolVenue.read(manager, gap.toId(), gap.tickSpacing, true, _lim(true));
        PoolVenue.Pool memory cut =
            PoolVenue.readTo(manager, gap.toId(), gap.tickSpacing, true, _lim(true), 1_000_000e6, true);
        assertEq(cut.segments.length, full.segments.length, "all segments");
        assertEq(cut.truncated, full.truncated, "truncated as the unbounded walk");
        assertEq(cut.steps, full.steps, "same steps");
        assertEq(full.segments.length, 8, "the gapped pool walks 8 segments");
    }

    /// @dev The walk is what costs gas: a small trade on the v1 pool plans in well under the unbounded walk's cost.
    function test_V211_planOnTheV1PoolSkipsTheLongWalk() public {
        _initExact(keyV2);
        _makers(1);
        _nextBlock(12);
        (int24 snap, int56 emaX,) = hookV2.anchorOfX(idV2);
        _coolAll();
        uint256 g = gasleft();
        splitter.planExactIn(keyV2, true, TickMath.MIN_SQRT_PRICE + 1, EXACT_IN_USDC, snap, emaX);
        g -= gasleft();
        assertLt(g, 190_000, "planExactIn, 1 maker, cold (M11 before: 228,418)");
    }

    // ------------------------------------------------------------------------------------------ lever 2: readOut

    /// @dev The exact-output read as it was before V2-11: `read` (exact-input caps), then `capsOut` over it.
    function _oldReadOut(MakerVenue.Entry[] memory e, bool zfo, int24 snap, int56 emaX)
        internal
        view
        returns (MakerVenue.Maker[] memory out)
    {
        out = MakerVenue.read(manager, keyV2, _guard(), e, zfo, snap, emaX);
        address tokenIn = zfo ? USDC : address(mumb);
        address tokenOut = zfo ? address(mumb) : USDC;
        uint256 pm = IERC20(tokenIn).balanceOf(address(manager));
        for (uint256 i; i < out.length; i++) {
            MakerVenue.Maker memory m = out[i];
            if (m.x == 0 || m.y == 0) continue;
            (m.status, m.capMin, m.capOut, m.capIn) = MakerVenue.capsOut(
                m.x, m.y, m.feeE9, MakerVenue.real(tokenOut, m.maker, m.y), pm, snap, zfo, e[i].params.bandBps
            );
        }
    }

    function _entries() internal view returns (MakerVenue.Entry[] memory e) {
        ConfluenceHook.Slot[] memory s = hookV2.strategiesOf(idV2);
        e = new MakerVenue.Entry[](s.length);
        for (uint256 j; j < s.length; j++) {
            e[j] = MakerVenue.Entry({maker: s[j].maker, params: s[j].params, strategyHash: s[j].strategyHash});
        }
    }

    /// @dev The folded `readOut` returns exactly what read-then-`capsOut` returned, for healthy, drained and revoked
    ///      makers, both directions.
    function test_V211_readOutEqualsReadThenCapsOut() public {
        _initExact(keyV2);
        _makers(6);
        // maker 2 drained of MUMB, maker 3 revoked its MUMB allowance, maker 4 revoked its USDC allowance
        uint256 bal2 = mumb.balanceOf(makers[2]);
        vm.prank(makers[2]);
        mumb.transfer(address(0xdead), bal2);
        vm.prank(makers[3]);
        mumb.approve(AQUA, 0);
        vm.prank(makers[4]);
        IERC20(USDC).approve(AQUA, 0);
        _nextBlock(12);
        (int24 snap, int56 emaX,) = hookV2.anchorOfX(idV2);
        MakerVenue.Entry[] memory e = _entries();
        for (uint256 d; d < 2; d++) {
            bool zfo = d == 0;
            MakerVenue.Maker[] memory a = MakerVenue.readOut(manager, keyV2, _guard(), e, zfo, snap, emaX);
            MakerVenue.Maker[] memory b = _oldReadOut(e, zfo, snap, emaX);
            assertEq(a.length, b.length, "same length");
            uint256 usable;
            for (uint256 i; i < a.length; i++) {
                assertEq(a[i].maker, b[i].maker, "maker");
                assertEq(a[i].strategyHash, b[i].strategyHash, "hash");
                assertEq(uint8(a[i].status), uint8(b[i].status), "status");
                assertEq(a[i].x, b[i].x, "x");
                assertEq(a[i].y, b[i].y, "y");
                assertEq(a[i].feeE9, b[i].feeE9, "fee");
                assertEq(a[i].capMin, b[i].capMin, "capMin");
                assertEq(a[i].capIn, b[i].capIn, "capIn");
                assertEq(a[i].capOut, b[i].capOut, "capOut");
                if (a[i].status == MakerVenue.Status.OK) usable++;
            }
            assertGe(usable, 2, "the comparison covers usable makers");
            assertLt(usable, 6, "and unusable ones");
        }
    }

    /// @dev The exact-output plan, cold, USDC in, 1 / 3 / 6 makers: M11 before V2-11 239,906 / 382,037 / 636,286;
    ///      with lever 1 166,350 / 308,347 / 562,351; with levers 1 and 2 about 152,000 / 270,000 / 488,000.
    function test_V211_planExactOutGas() public {
        uint8[3] memory ns = [1, 3, 6];
        uint256[3] memory ceil = [uint256(160_000), 290_000, 520_000];
        _initExact(keyV2);
        bn0 = block.number;
        ts0 = block.timestamp;
        uint256 base = vm.snapshotState();
        for (uint256 i; i < 3; i++) {
            vm.revertToState(base);
            _makers(ns[i]);
            _nextBlockM11();
            (int24 snap, int56 emaX,) = hookV2.anchorOfX(idV2);
            _coolAll();
            uint256 g = gasleft();
            splitterOut.planExactOut(keyV2, true, TickMath.MIN_SQRT_PRICE + 1, EXACT_OUT_MUMB, snap, emaX);
            g -= gasleft();
            assertLt(g, ceil[i], string.concat("planExactOut gas, ", vm.toString(uint256(ns[i])), " makers"));
        }
    }

    // ------------------------------------------------------------------------------------------ lever 8: step cost

    /// @dev Pool-only swap gas on the gapped pool by number of initialised ticks crossed, cold, after a swap in the
    ///      other direction (both fee-growth globals nonzero: each crossing writes two fresh tick slots, the worst
    ///      case). Logs the cost per crossing.
    function test_V211_stepCost() public {
        PoolKey memory gap = _gapKey();
        _initExact(gap);
        _swap(gap, trader, false, -int256(1e18), ""); // MUMB in: the other global becomes nonzero
        bn0 = block.number;
        ts0 = block.timestamp;
        uint256 base = vm.snapshotState();
        uint256[8] memory amts = [uint256(50), 250, 400, 520, 600, 700, 850, 960];
        uint256 g0;
        for (uint256 i; i < amts.length; i++) {
            vm.revertToState(base);
            (uint256 g,) = _m11(gap, true, true, amts[i] * 1e6);
            uint256 c = _crossed(gap);
            if (i == 0) g0 = g;
            console2.log("usdc / crossed / gas / per crossing", amts[i], c, g);
            if (c > 0) console2.log("   per crossing", (g - g0) / c);
        }
        // hops: a swap that runs the walk bound through empty bitmap words on the v1 pool
        vm.revertToState(base);
        (uint256 gv,) = _m11(keyV2, true, true, 1_000e6);
        vm.revertToState(base);
        _fund(trader, 0, 1_000_000e6);
        (uint256 gh,) = _m11(keyV2, true, true, 500_000e6);
        console2.log("v1 pool: 1,000 USDC / 500,000 USDC (runs to the price limit)", gv, gh);
    }

    // ------------------------------------------------------------------------------------------ lever 8: the reserve

    function _planOn(PoolKey memory k, bool exactIn, uint256 amount) internal returns (Plan memory p) {
        _nextBlock(12);
        (int24 snap, int56 emaX,) = hookV2.anchorOfX(k.toId());
        p = exactIn
            ? splitter.planExactIn(k, true, TickMath.MIN_SQRT_PRICE + 1, amount, snap, emaX)
            : splitterOut.planExactOut(k, true, TickMath.MIN_SQRT_PRICE + 1, amount, snap, emaX);
    }

    /// @dev The plan carries the walk's step count (bits 8 and up of `truncated`, bit 0 the flag), and the hook's
    ///      reserve for it is the base plus a step's worst case per step; a walk that did not cover the amount gets the
    ///      stated maximum.
    function test_V211_planCarriesTheStepsAndTheReserveFollows() public {
        PoolKey memory gap = _gapKey();
        _initExact(gap);
        _gasMakers(gap, 3);
        uint256[3] memory usdc = [uint256(100), 600, 1_000];
        for (uint256 i; i < 3; i++) {
            Plan memory p = _planOn(gap, true, usdc[i] * 1e6);
            PoolVenue.Pool memory pool = PoolVenue.readTo(
                manager, gap.toId(), gap.tickSpacing, true, TickMath.MIN_SQRT_PRICE + 1, usdc[i] * 1e6, true
            );
            assertEq(p.truncated & 1, pool.truncated ? 1 : 0, "the truncated flag is bit 0");
            assertEq(p.truncated >> 8, pool.steps, "the steps are carried");
            assertGt(pool.steps, 0, "the walk took steps");
            assertEq(
                PlanCheck.reserve(p),
                pool.truncated ? PlanCheck.RESERVE_MAX : PlanCheck.GAS_RESERVE + PlanCheck.STEP_GAS * pool.steps,
                "exact-in reserve"
            );
        }
        // past the pool's liquidity the walk stops at its bound: the stated maximum
        Plan memory big = _planOn(gap, true, 5_000e6);
        assertEq(big.truncated & 1, 1, "5,000 USDC is past the walk");
        assertEq(PlanCheck.reserve(big), PlanCheck.RESERVE_MAX, "stated maximum when the walk did not cover the amount");
        // exact output
        Plan memory o = _planOn(gap, false, 100e18);
        assertEq(
            o.truncated >> 8,
            PoolVenue.readTo(manager, gap.toId(), gap.tickSpacing, true, TickMath.MIN_SQRT_PRICE + 1, 100e18, false)
            .steps,
            "exact-out steps"
        );
        assertEq(
            PlanCheck.reserve(o), PlanCheck.GAS_RESERVE + PlanCheck.STEP_GAS * (o.truncated >> 8), "exact-out reserve"
        );
    }

    /// @dev The hook refuses a plan whose step count is past the walk's bound, or whose flag bits are not 0 / 1 plus a
    ///      step count: a reserve the hook cannot bound is no reserve.
    function test_V211_checkBoundsTheStepCount() public {
        PoolKey memory gap = _gapKey();
        _initExact(gap);
        _gasMakers(gap, 3);
        Plan memory p = _planOn(gap, true, 1_000e6);
        assertTrue(PlanCheck.check(p, manager, USDC, 1_000e6, 3, true), "premise: the honest plan passes");
        p.truncated = (PoolVenue.MAX_TICK_STEPS + 1) << 8;
        assertFalse(PlanCheck.check(p, manager, USDC, 1_000e6, 3, true), "steps past MAX_TICK_STEPS");
        p = _planOn(gap, true, 1_000e6);
        p.truncated |= 2;
        assertFalse(PlanCheck.check(p, manager, USDC, 1_000e6, 3, true), "a flag bit that is not defined");
        p = _planOn(gap, true, 1_000e6);
        p.truncated = PoolVenue.MAX_TICK_STEPS << 8;
        assertTrue(PlanCheck.check(p, manager, USDC, 1_000e6, 3, true), "steps at the bound are accepted");
    }

    // ------------------------------------------------------------------------------------------ gas estimators

    /// @dev "Pool-only" for the never-revert claim: the same hooked pool, makers registered, every leg skipped (both
    ///      splitters revert, so the plan is SKIP_PLAN and the pool takes the whole amount). Not a hookless pool.
    function _skipLegs() internal {
        vm.etch(address(splitter), hex"5f5ffd");
        vm.etch(address(splitterOut), hex"5f5ffd");
    }

    /// @dev One hooked swap at `limit`: whether it passed, the gas it used, the legs FILLED. State is restored.
    function _probe(PoolKey memory k, uint256 limit, bool exactIn, uint256 amount)
        internal
        returns (bool ok, uint256 used, uint256 filled)
    {
        uint256 s = vm.snapshotState();
        vm.startPrank(trader);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        mumb.approve(address(swapRouter), type(uint256).max);
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: exactIn ? -int256(amount) : int256(amount), sqrtPriceLimitX96: _lim(true)
        });
        vm.recordLogs();
        uint256 g = gasleft();
        try swapRouter.swap{gas: limit}(
            k, sp, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        ) {
            ok = true;
        } catch {}
        used = g - gasleft();
        vm.stopPrank();
        (ConfluenceHook.Leg[] memory legs,) = _legsFrom(vm.getRecordedLogs(), address(hookV2));
        filled = _countStatus(legs, LegStatus.FILLED);
        vm.revertToState(s);
    }

    /// @dev What eth_estimateGas and a wallet would find, per fixture: gasUsed at a high limit, the retries at
    ///      used*64/63 and +50,000, and a binary search from 21,000 (the lowest limit that passes).
    function _estimators(bool exactIn) internal {
        uint256 base = vm.snapshotState();
        for (uint256 id; id < FIXTURES; id++) {
            vm.revertToState(base);
            (PoolKey memory k, uint256 amount) = _fixture(id, exactIn);
            (, uint256 used, uint256 full) = _probe(k, 8_000_000, exactIn, amount);
            (bool ok1,, uint256 f1) = _probe(k, used * 64 / 63, exactIn, amount);
            (bool ok2,, uint256 f2) = _probe(k, used * 64 / 63 + 50_000, exactIn, amount);
            uint256 lo = 21_000;
            uint256 hi = used * 64 / 63;
            while (hi - lo > 500) {
                uint256 mid = (lo + hi) / 2;
                (bool okm,,) = _probe(k, mid, exactIn, amount);
                if (okm) hi = mid;
                else lo = mid;
            }
            (,, uint256 fb) = _probe(k, hi, exactIn, amount);
            uint256 s0 = vm.snapshotState();
            _skipLegs();
            uint256 plo = 21_000;
            uint256 phi = used * 64 / 63;
            while (phi - plo > 500) {
                uint256 mid = (plo + phi) / 2;
                (bool okp,,) = _probe(k, mid, exactIn, amount);
                if (okp) phi = mid;
                else plo = mid;
            }
            vm.revertToState(s0);
            console2.log("   pool-only (same hook, legs skipped) min limit", phi);
            console2.log(
                string.concat("fixture ", vm.toString(id), exactIn ? " in" : " out"), "used / legs at high limit:", used
            );
            console2.log("   full legs", full);
            console2.log("   at used*64/63: ok / legs filled", ok1 ? 1 : 0, f1);
            console2.log("   at +50,000:    ok / legs filled", ok2 ? 1 : 0, f2);
            console2.log("   binary search: limit / legs filled", hi, fb);
        }
    }

    function test_V211_estimators_in() public {
        _estimators(true);
    }

    function test_V211_estimators_out() public {
        _estimators(false);
    }

    // ------------------------------------------------------------------------------------------ price of the design

    /// @dev Legs filled and the result against the same hooked pool with legs skipped, from one snapshot, ample gas.
    ///      Exact in: MUMB out (bigger is better). Exact out: USDC in (smaller is better).
    function _priceCompare(PoolKey memory k, bool exactIn, uint256 amount, string memory label) internal {
        uint256 s = vm.snapshotState();
        uint256 u0 = IERC20(USDC).balanceOf(trader);
        uint256 m0 = mumb.balanceOf(trader);
        vm.recordLogs();
        _swap(k, trader, true, exactIn ? -int256(amount) : int256(amount), "");
        (ConfluenceHook.Leg[] memory legs,) = _legsFrom(vm.getRecordedLogs(), address(hookV2));
        uint256 filled = _countStatus(legs, LegStatus.FILLED);
        uint256 hookedOut = mumb.balanceOf(trader) - m0;
        uint256 hookedIn = u0 - IERC20(USDC).balanceOf(trader);
        vm.revertToState(s);
        _skipLegs();
        _swap(k, trader, true, exactIn ? -int256(amount) : int256(amount), "");
        uint256 poolOut = mumb.balanceOf(trader) - m0;
        uint256 poolIn = u0 - IERC20(USDC).balanceOf(trader);
        vm.revertToState(s);
        console2.log(label, "legs filled", filled);
        if (exactIn) console2.log("   MUMB out hooked / pool-only", hookedOut, poolOut);
        else console2.log("   USDC in hooked / pool-only", hookedIn, poolIn);
    }

    function test_V211_priceOnTheGappedPool() public {
        PoolKey memory k = _gapKey();
        _initExact(k);
        _gasMakers(k, 3);
        _nextBlock(12);
        _priceCompare(k, true, 1_000e6, "exact-in 1,000 USDC");
        _priceCompare(k, true, 2_500e6, "exact-in 2,500 USDC");
        _priceCompare(k, true, 5_000e6, "exact-in 5,000 USDC");
        _priceCompare(k, false, 990e18, "exact-out 990 MUMB");
        _priceCompare(k, false, 2_475e18, "exact-out 2,475 MUMB");
        _priceCompare(k, false, 4_950e18, "exact-out 4,950 MUMB");
    }

    /// @dev The scope of "never reverts where pool-only passes": the pool-only path fits the walk bound (the walk covers
    ///      the amount, `truncated` is 0) on every fixture except fixture 1, whose window is pinned in `_pin`.
    function test_V211_onlyFixture1IsPastTheWalkBound() public {
        uint256 base = vm.snapshotState();
        for (uint256 id; id < FIXTURES; id++) {
            for (uint256 m; m < 2; m++) {
                vm.revertToState(base);
                (PoolKey memory k, uint256 amount) = _fixture(id, m == 0);
                Plan memory p = _planOn(k, m == 0, amount);
                assertEq(
                    p.truncated & 1,
                    id == 1 ? 1 : 0,
                    string.concat("fixture ", vm.toString(id), m == 0 ? " in" : " out", ": walk bound")
                );
            }
        }
    }

    /// @dev Report for the walk-bound measurement (D-41): the reserve constants and, per fixture and mode, the plan's
    ///      truncated flag and step count.
    function test_V211_boundReport() public {
        console2.log("MAX_TICK_STEPS / RESERVE_MAX / gate", PoolVenue.MAX_TICK_STEPS, PlanCheck.RESERVE_MAX);
        console2.log("gate (RESERVE_MAX + MIN_LEG_GAS)", PlanCheck.RESERVE_MAX + PlanCheck.MIN_LEG_GAS);
        uint256 base = vm.snapshotState();
        for (uint256 id; id < FIXTURES; id++) {
            for (uint256 m; m < 2; m++) {
                vm.revertToState(base);
                (PoolKey memory k, uint256 amount) = _fixture(id, m == 0);
                Plan memory p = _planOn(k, m == 0, amount);
                console2.log(
                    string.concat("fixture ", vm.toString(id), m == 0 ? " in" : " out", ": truncated / steps"),
                    p.truncated & 1,
                    p.truncated >> 8
                );
            }
        }
    }

    /// @dev Report: the hostile swaps' gas (burning guard on every leg; burning splitter), ample gas.
    function test_V211_hostileReport() public {
        uint256 base = vm.snapshotState();
        for (uint256 m; m < 2; m++) {
            for (uint256 v = 1; v <= 2; v++) {
                vm.revertToState(base);
                (PoolKey memory k, uint256 amount) = _fixture(3, m == 0);
                if (v == 1) {
                    vm.etch(_guard(), _burnerCode());
                } else {
                    vm.etch(address(splitter), _burnerCode());
                    vm.etch(address(splitterOut), _burnerCode());
                }
                (uint256 gas_, uint256 filled) = _m11(k, true, m == 0, amount);
                console2.log(
                    string.concat(m == 0 ? "exact-in " : "exact-out ", v == 1 ? "burning guard" : "burning splitter"),
                    gas_,
                    filled
                );
            }
        }
    }

    // ------------------------------------------------------------------------------------------ ceilings (D-41)

    /// @dev Each ceiling is the M11 value measured on this tree plus 5%, rounded up to 1,000. 6 makers, 3 legs, v1 pool:
    ///      index = direction x 2 + mode (USDC in exact-in, USDC in exact-out, MUMB in exact-in, MUMB in exact-out).
    function _honestCeil(uint256 d, uint256 m) internal pure returns (uint256) {
        return [uint256(1_336_000), 1_324_000, 1_371_000, 1_356_000][d * 2 + m];
    }

    /// @dev The gapped pool, 3 legs, the large size (exact in 2,500 USDC, exact out 400 MUMB).
    uint256 internal constant GAP_3L_IN_CEIL = 1_341_000;
    uint256 internal constant GAP_3L_OUT_CEIL = 1_109_000;
    /// @dev Burning guard on all 3 legs (each cut at `LEG_GAS_CAP`), exact in / exact out; burning splitter (cut at
    ///      `PLAN_GAS_CAP`, then the pool alone).
    uint256 internal constant BURN_GUARD_IN_CEIL = 2_927_000;
    uint256 internal constant BURN_GUARD_OUT_CEIL = 2_913_000;
    uint256 internal constant BURN_SPLITTER_CEIL = 2_066_000;
    /// @dev The hook's own work on top of the caps (measured: a burning-guard swap less 3 x `LEG_GAS_CAP`, 866,907, plus 5%).
    uint256 internal constant HOOK_WORK = 910_000;
    uint256 internal constant EIP_7825_TX_CAP = 16_777_216;

    /// @dev The worst honest swap (6 makers, 3 legs, both modes, both directions; the gapped pool with 3 legs at the
    ///      large size) is within its ceiling; the worst hostile swaps are within theirs and under the analytic bound
    ///      `PLAN_GAS_CAP + 3 x LEG_GAS_CAP + hook work`, which is under the EIP-7825 transaction cap.
    function test_V211_worstCaseBelowCeiling() public {
        _initExact(keyV2);
        bn0 = block.number;
        ts0 = block.timestamp;
        _makers(6);
        uint256 base = vm.snapshotState();
        for (uint256 d; d < 2; d++) {
            for (uint256 m; m < 2; m++) {
                vm.revertToState(base);
                (uint256 g, uint256 f) = _m11(keyV2, d == 0, m == 0, _amount(d == 0, m == 0));
                assertEq(f, 3, "three legs fill");
                assertLe(g, _honestCeil(d, m), "honest worst case within its ceiling");
            }
        }
        // The analytic hostile bound.
        uint256 bound = PlanCheck.PLAN_GAS_CAP + 3 * PlanCheck.LEG_GAS_CAP + HOOK_WORK;
        assertLt(bound, EIP_7825_TX_CAP, "under the EIP-7825 transaction gas cap");
        for (uint256 m; m < 2; m++) {
            vm.revertToState(base);
            vm.etch(_guard(), _burnerCode());
            (uint256 g, uint256 f) = _m11(keyV2, true, m == 0, _amount(true, m == 0));
            assertEq(f, 0, "burning legs never fill");
            assertLe(g, m == 0 ? BURN_GUARD_IN_CEIL : BURN_GUARD_OUT_CEIL, "burning guard within its ceiling");
            assertLe(g, bound, "burning guard under the analytic bound");
            vm.revertToState(base);
            vm.etch(address(splitter), _burnerCode());
            vm.etch(address(splitterOut), _burnerCode());
            (g, f) = _m11(keyV2, true, m == 0, _amount(true, m == 0));
            assertEq(f, 0, "a burning splitter never fills");
            assertLe(g, BURN_SPLITTER_CEIL, "burning splitter within its ceiling");
            assertLe(g, bound, "burning splitter under the analytic bound");
        }
        vm.revertToState(base);
        for (uint256 m; m < 2; m++) {
            uint256 s = vm.snapshotState();
            (uint256 g,) = _scenario(3, 2, m == 0);
            assertLe(g, m == 0 ? GAP_3L_IN_CEIL : GAP_3L_OUT_CEIL, "gapped pool, 3 legs, large");
            vm.revertToState(s);
        }
    }

    /// @dev A swap sent with the Lens's `minHookGas` plus the pool's share fills every planned leg, never SKIP_GAS.
    function test_V211_noLegSkipGasAtMinHookGas() public {
        ConfluenceLens lens = new ConfluenceLens();
        uint256 base = vm.snapshotState();
        for (uint256 id; id < FIXTURES; id++) {
            for (uint256 m; m < 2; m++) {
                vm.revertToState(base);
                (PoolKey memory k, uint256 amount) = _fixture(id, m == 0);
                ConfluenceLens.Breakdown memory q = lens.quote(k, true, m == 0 ? -int256(amount) : int256(amount));
                uint256 planned;
                for (uint256 i; i < q.legs.length; i++) {
                    if (q.legs[i].amountIn > 0) planned++;
                }
                if (planned == 0) continue;
                (bool ok,, uint256 filled) = _probe(k, q.minHookGas + 300_000, m == 0, amount);
                assertTrue(ok, "the swap passes at minHookGas + the pool's share");
                assertEq(filled, planned, string.concat("fixture ", vm.toString(id), ": every planned leg fills"));
            }
        }
    }
}
