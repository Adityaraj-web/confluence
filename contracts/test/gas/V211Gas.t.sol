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

import {LegStatus} from "../../src/ConfluenceSplitter.sol";
import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {MakerVenue} from "../../src/libraries/MakerVenue.sol";
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
        for (uint256 g = 285_000; g <= 500_000; g += 5_000) l[n++] = g;
        for (uint256 g = 550_000; g <= 1_000_000; g += 50_000) l[n++] = g;
        for (uint256 g = 1_100_000; g <= 3_000_000; g += 100_000) l[n++] = g;
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
                zeroForOne: true, amountSpecified: exactIn ? -int256(amount) : int256(amount), sqrtPriceLimitX96: _lim(true)
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

    /// @dev At every limit where the pool-only swap passes, the hooked swap passes and the hook ends clean.
    function _sweep(PoolKey memory k, bool exactIn, uint256 amount, string memory label)
        internal
        returns (uint256 checked, uint256 filled, uint256 failures, uint256 maxFailLimit, uint256 minFailLimit)
    {
        uint256[] memory limits = _limits();
        minFailLimit = type(uint256).max;
        for (uint256 i; i < limits.length; i++) {
            uint256 s = vm.snapshotState();
            _unregisterAll(k);
            bool poolOk = _tryAtLimit(k, limits[i], exactIn, amount);
            vm.revertToState(s);
            if (!poolOk) continue;
            checked++;
            vm.recordLogs();
            bool ok = _tryAtLimit(k, limits[i], exactIn, amount);
            if (!ok && report) {
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
                    _sweep(k, exactIn, amount, label);
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
        PoolVenue.Pool memory cut = PoolVenue.readTo(manager, k.toId(), k.tickSpacing, true, _lim(true), amount, exactIn);
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
}
