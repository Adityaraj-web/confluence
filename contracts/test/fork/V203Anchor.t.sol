// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {AnchorLib} from "../../src/libraries/AnchorLib.sol";
import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {PoolBase} from "../base/PoolBase.t.sol";

/// @notice V2-03 maths without a fork: the EMA's fixed point, rounding around zero and at the tick bounds, and
/// 2^(-dt/H). Choices are in D-31.
contract V203AnchorMathTest is Test {
    uint256 internal constant H = 60;
    int256 internal constant X16 = 1 << 16;
    int256 internal constant MAXT = 887_272; // TickMath.MAX_TICK, which is also -MIN_TICK
    uint256 internal constant Q128 = 1 << 128;
    /// @dev Named bound for the convergence loops below.
    uint256 internal constant MAX_STEPS = 5_000;

    // ------------------------------------------------------------------ risk 2: exp2

    /// @dev decayX128(2^(32-i), 2^32) isolates constant C_i (x = dt, one bit set). i = 0 is dt = H: exactly 2^127.
    function _c(uint256 i) internal pure returns (uint256) {
        return AnchorLib.decayX128(1 << (32 - i), 1 << 32);
    }

    function test_V203_exp2ExactPoints() public pure {
        uint256[4] memory hs = [uint256(2), 60, 3600, 1 << 32];
        for (uint256 j; j < hs.length; ++j) {
            uint256 h = hs[j];
            assertEq(AnchorLib.decayX128(0, h), Q128, "dt = 0");
            for (uint256 k = 1; k <= 15; ++k) {
                assertEq(AnchorLib.decayX128(k * h, h), Q128 >> k, "dt = kH");
            }
            assertEq(AnchorLib.decayX128(16 * h, h), 0, "dt = 16H cut-off");
            assertEq(AnchorLib.decayX128(16 * h + 1, h), 0, "past the cut-off");
            assertEq(AnchorLib.decayX128(type(uint256).max, h), 0, "max dt");
            assertGt(AnchorLib.decayX128(16 * h - 1, h), 0, "just under the cut-off");
        }
        // dt = H/2: 2^(-1/2) = sqrt(2^255) (floor), to the ulp of the bit decomposition (one bit: C_1).
        assertEq(AnchorLib.decayX128(30, 60), Math.sqrt(1 << 255), "dt = H/2");
        assertEq(_c(1), Math.sqrt(1 << 255), "C_1 = 2^(-1/2)");
        // The 32 constants chain: C_i^2 = C_(i-1) to within 3 ulp (each is a floor of a value below 2^128).
        assertEq(_c(0), Q128 >> 1, "C_0 = 1/2");
        for (uint256 i = 1; i <= 32; ++i) {
            uint256 sq = (_c(i) * _c(i)) >> 128;
            uint256 prev = _c(i - 1);
            uint256 diff = sq > prev ? sq - prev : prev - sq;
            assertLe(diff, 3, "C_i^2 vs C_(i-1)");
        }
    }

    function testFuzz_V203_exp2Monotonic(uint256 hSeed, uint256 dt1, uint256 dt2, bool useHook) public pure {
        uint256 h = useHook ? H : bound(hSeed, 1, 1 << 32);
        dt1 = bound(dt1, 0, 17 * h);
        dt2 = bound(dt2, 0, 17 * h);
        (uint256 lo, uint256 hi) = dt1 <= dt2 ? (dt1, dt2) : (dt2, dt1);
        uint256 fLo = AnchorLib.decayX128(lo, h);
        uint256 fHi = AnchorLib.decayX128(hi, h);
        assertLe(fHi, fLo, "monotonic non-increasing");
        assertLe(fLo, Q128, "at most 1");
        // Whole half-lives differ by a factor of two, so the function strictly decreases at that distance.
        if (hi - lo >= h && hi < 16 * h && fLo > 1) assertLt(fHi, fLo, "strictly decreasing");
    }

    /// @dev Accuracy: f(a + b) = f(a) f(b) to 2^-30 relative (plus 2^-100 absolute for tiny values), below the
    ///      cut-off. At 16H the factor drops from 2^-16 to 0: that jump is the documented cost of the cut-off (D-31).
    function testFuzz_V203_exp2Accuracy(uint256 a, uint256 b, bool useHook, uint256 hSeed) public pure {
        uint256 h = useHook ? H : bound(hSeed, 1, 1 << 32);
        a = bound(a, 0, 8 * h - 1);
        b = bound(b, 0, 8 * h - 1);
        uint256 fab = AnchorLib.decayX128(a + b, h);
        uint256 prod = Math.mulDiv(AnchorLib.decayX128(a, h), AnchorLib.decayX128(b, h), Q128);
        uint256 diff = fab > prod ? fab - prod : prod - fab;
        assertLe(diff, (prod >> 30) + (1 << 28), "f(a+b) vs f(a) f(b)");
    }

    // ------------------------------------------------------------------ risk 1: rounding for negative values

    function test_V203_emaTickRoundsToNearest() public pure {
        assertEq(AnchorLib.emaTick(0), 0);
        assertEq(AnchorLib.emaTick(-111_411), -2, "-1.7");
        assertEq(AnchorLib.emaTick(-98_304), -1, "-1.5 ties up");
        assertEq(AnchorLib.emaTick(-33_423), -1, "-0.51");
        assertEq(AnchorLib.emaTick(-32_768), 0, "-0.5 ties up");
        assertEq(AnchorLib.emaTick(-19_661), 0, "-0.3");
        assertEq(AnchorLib.emaTick(32_112), 0, "+0.49");
        assertEq(AnchorLib.emaTick(32_768), 1, "+0.5 ties up");
        assertEq(AnchorLib.emaTick(98_304), 2, "+1.5 ties up");
        // Every bucket is 2^16 wide: ticks t at t * 2^16 +- (2^15 - 1) read t, on both sides of zero.
        for (int256 t = -3; t <= 3; ++t) {
            assertEq(AnchorLib.emaTick(int56(t * X16 - 32_767)), int24(t), "bucket low edge");
            assertEq(AnchorLib.emaTick(int56(t * X16 + 32_767)), int24(t), "bucket high edge");
        }
        assertEq(AnchorLib.emaTick(int56(MAXT * X16)), int24(MAXT), "max tick");
        assertEq(AnchorLib.emaTick(int56(-MAXT * X16)), int24(-MAXT), "min tick");
    }

    /// @dev The deviation from the snapshot shrinks toward zero from either side: -1 unit does not stay at -1.
    function test_V203_emaRoundsAroundZero() public pure {
        assertEq(AnchorLib.nextEmaX(1, 0, 1, H), 0, "+1 unit decays to 0");
        assertEq(AnchorLib.nextEmaX(-1, 0, 1, H), 0, "-1 unit decays to 0 (a floor would leave -1)");
        assertEq(AnchorLib.nextEmaX(0, 0, 1, H), 0);
        // Snapshots either side of zero: the same deviation gives the mirrored result.
        assertEq(AnchorLib.nextEmaX(3 * X16, -1, H, H), -X16 + (4 * X16) / 2, "snap -1, ema 3, one half-life");
        assertEq(AnchorLib.nextEmaX(-3 * X16, 1, H, H), X16 - (4 * X16) / 2, "snap 1, ema -3, one half-life");
        // Many dt = 1 steps from +5 and -5 ticks around snapshot 0 and +-1 reach it exactly, in the same steps.
        int24[3] memory snaps = [int24(0), int24(-1), int24(1)];
        for (uint256 s; s < snaps.length; ++s) {
            (int256 up, uint256 nUp) = _converge(snaps[s], int256(snaps[s]) * X16 + 5 * X16);
            (int256 dn, uint256 nDn) = _converge(snaps[s], int256(snaps[s]) * X16 - 5 * X16);
            assertEq(up, int256(snaps[s]) * X16, "from above reaches the snapshot");
            assertEq(dn, int256(snaps[s]) * X16, "from below reaches the snapshot");
            assertEq(nUp, nDn, "same number of steps");
            assertLt(nUp, MAX_STEPS, "converges");
        }
    }

    function _converge(int24 snap, int256 emaX) internal pure returns (int256, uint256 steps) {
        while (emaX != int256(snap) * X16 && steps < MAX_STEPS) {
            emaX = AnchorLib.nextEmaX(emaX, snap, 1, H);
            ++steps;
        }
        return (emaX, steps);
    }

    /// @dev At dt = H the factor is exactly 1/2, so the results are exact at the tick bounds.
    function test_V203_emaDeepNegativeTicks() public pure {
        int256 span = 2 * MAXT * X16;
        assertEq(AnchorLib.nextEmaX(MAXT * X16, int24(-MAXT), H, H), 0, "MIN snap, MAX ema, H: the middle");
        assertEq(AnchorLib.nextEmaX(-MAXT * X16, int24(MAXT), H, H), 0, "MAX snap, MIN ema, H: the middle");
        assertEq(AnchorLib.nextEmaX(MAXT * X16, int24(-MAXT), 2 * H, H), -MAXT * X16 + span / 4, "2H up");
        assertEq(AnchorLib.nextEmaX(-MAXT * X16, int24(MAXT), 2 * H, H), MAXT * X16 - span / 4, "2H down");
        assertEq(AnchorLib.nextEmaX(MAXT * X16, int24(-MAXT), 0, H), MAXT * X16, "dt = 0: unchanged");
        assertEq(AnchorLib.nextEmaX(-MAXT * X16, int24(-MAXT), 7 * H, H), -MAXT * X16, "at the snapshot: stays");
        // Deep negative, odd deviation: truncates toward the snapshot (from below: up).
        assertEq(AnchorLib.nextEmaX(-MAXT * X16 + 1, int24(-MAXT), H, H), -MAXT * X16, "1 unit above MIN, H");
        assertEq(AnchorLib.nextEmaX(-MAXT * X16 + 3, int24(-MAXT), H, H), -MAXT * X16 + 1, "3 units above MIN, H");
        assertEq(AnchorLib.nextEmaX(MAXT * X16 - 3, int24(MAXT), H, H), MAXT * X16 - 1, "3 units below MAX, H");
    }

    function testFuzz_V203_emaMirrorSymmetric(int256 snapSeed, int256 emaSeed, uint256 dt, bool useHook, uint256 h)
        public
        pure
    {
        int24 snap = int24(bound(snapSeed, -MAXT, MAXT));
        int256 emaX = bound(emaSeed, -MAXT * X16, MAXT * X16);
        uint256 half = useHook ? H : bound(h, 1, 1 << 32);
        dt = bound(dt, 0, 20 * half);
        int56 a = AnchorLib.nextEmaX(emaX, snap, dt, half);
        int56 b = AnchorLib.nextEmaX(-emaX, -snap, dt, half);
        assertEq(int256(a), -int256(b), "next(-s, -e) == -next(s, e)");
        // Between the old EMA and the snapshot, never past either.
        int256 lo = emaX < int256(snap) * X16 ? emaX : int256(snap) * X16;
        int256 hi = emaX < int256(snap) * X16 ? int256(snap) * X16 : emaX;
        assertGe(int256(a), lo);
        assertLe(int256(a), hi);
        if (dt == 0) assertEq(int256(a), emaX, "dt = 0 leaves the EMA exactly");
    }

    function testFuzz_V203_emaBounded(uint256 seed) public pure {
        AnchorLib.Anchor memory a;
        int256 minSnap = type(int256).max;
        int256 maxSnap = type(int256).min;
        uint256 ts = 1_700_000_000;
        for (uint256 i; i < 8; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            int256 t = int256(r % uint256(2 * MAXT + 1)) - MAXT;
            if (r >> 250 == 0) t = MAXT;
            else if (r >> 250 == 1) t = -MAXT;
            else if (r >> 250 == 2) t = 0;
            uint256 dt = uint256(keccak256(abi.encode(r, "dt")));
            dt = dt % 3 == 0 ? dt % (1 << 38) : dt % (20 * H);
            ts += dt;
            a = AnchorLib.next(a, int24(t), ts, i + 1, H);
            if (t < minSnap) minSnap = t;
            if (t > maxSnap) maxSnap = t;
            assertEq(int256(a.snapTick), t, "snapshot stored");
            assertGe(int256(a.emaTickX), minSnap * X16, "ema >= min snapshot");
            assertLe(int256(a.emaTickX), maxSnap * X16, "ema <= max snapshot");
            int256 et = AnchorLib.emaTick(a.emaTickX);
            assertGe(et, minSnap);
            assertLe(et, maxSnap);
        }
    }
}

/// @notice V2-03 on the mainnet fork: the v2 hook's anchor in a real v4 pool. Choices are in D-31.
contract V203AnchorTest is PoolBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant H = 60;
    uint256 internal constant BIG_USDC = 1000e6;
    uint256 internal constant BIG_MUMB = 1000e18;
    uint256 internal constant TINY_USDC = 1e6;

    ConfluenceHook internal hookV2;
    PoolKey internal keyV2;
    PoolId internal idV2;
    PoolKey internal plainKey;

    function setUp() public override {
        super.setUp();
        hookV2 = _deployHookV2();
        keyV2 = _createPool(IHooks(address(hookV2)));
        idV2 = keyV2.toId();
        plainKey = _createPool(IHooks(address(0)));
    }

    // ---------------------------------------------------------------- helpers

    struct Raw {
        uint40 ts;
        uint64 blk;
        int24 snap;
        int56 emaX;
        uint256 high; // bits 184..255
    }

    function _slotOf(PoolId id) internal pure returns (bytes32) {
        return keccak256(abi.encode(PoolId.unwrap(id), uint256(0)));
    }

    function _decode(uint256 w) internal pure returns (Raw memory r) {
        r.ts = uint40(w);
        r.blk = uint64(w >> 40);
        r.snap = int24(uint24(w >> 104));
        r.emaX = int56(uint56(w >> 128));
        r.high = w >> 184;
    }

    function _raw(PoolId id) internal view returns (Raw memory) {
        return _decode(uint256(vm.load(address(hookV2), _slotOf(id))));
    }

    function _encode(uint40 ts, uint64 blk, int24 snap, int56 emaX) internal pure returns (bytes32) {
        return
            bytes32(
                uint256(ts) | (uint256(blk) << 40) | (uint256(uint24(snap)) << 104) | (uint256(uint56(emaX)) << 128)
            );
    }

    function _tick(PoolId id) internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(id);
    }

    function _anchor() internal view returns (int24 s, int24 e, bool f) {
        return hookV2.anchorOf(idV2);
    }

    function _next(uint256 dt) internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    /// @dev A swap on the v2 pool: USDC in (buying MUMB) or MUMB in.
    function _buy(uint256 usdcIn) internal {
        _swap(keyV2, trader, usdcForMumb(), -int256(usdcIn), "");
    }

    function _sell(uint256 mumbIn) internal {
        _swap(keyV2, trader, !usdcForMumb(), -int256(mumbIn), "");
    }

    // ---------------------------------------------------------------- acceptance

    function test_V203_snapshotFixedWithinBlock() public {
        int24 t0 = _tick(idV2);
        _buy(TINY_USDC);
        (int24 snap0, int24 ema0, bool fresh0) = _anchor();
        assertTrue(fresh0, "stored this block");
        assertEq(snap0, t0, "snapshot is the tick before the first swap");
        assertEq(ema0, t0, "first touch: ema = snapshot");
        Raw memory r0 = _raw(idV2);

        _buy(BIG_USDC);
        int24 moved = _tick(idV2);
        assertTrue(moved != t0, "the swap moved slot0");
        (int24 s1, int24 e1, bool f1) = _anchor();
        assertEq(s1, snap0);
        assertEq(e1, ema0);
        assertTrue(f1);

        _sell(BIG_MUMB);
        _buy(BIG_USDC / 2);
        (int24 s2, int24 e2, bool f2) = _anchor();
        assertEq(s2, snap0, "snapshot unchanged after three more swaps");
        assertEq(e2, ema0);
        assertTrue(f2);
        Raw memory r1 = _raw(idV2);
        assertEq(abi.encode(r1.ts, r1.blk, r1.snap, r1.emaX), abi.encode(r0.ts, r0.blk, r0.snap, r0.emaX), "slot");

        _next(10);
        (int24 s3, int24 e3, bool f3) = _anchor();
        assertFalse(f3, "a new block: lazy");
        assertEq(s3, _tick(idV2), "the lazy snapshot is the current tick");
        assertTrue(s3 != snap0);
        assertTrue(e3 != s3, "ema lags");
    }

    /// @dev Risk 5: the lazy view before a block's first swap equals what the swap stores, for a range of gaps and
    ///      both directions (so the EMA sits below the snapshot in some blocks and above in others).
    function test_V203_viewEqualsStored() public {
        Raw memory z = _raw(idV2);
        assertEq(abi.encode(z.ts, z.blk, z.snap, z.emaX, z.high), abi.encode(0, 0, 0, 0, 0), "untouched slot is zero");

        uint256[10] memory dts = [uint256(0), 1, 30, H, 7 * H, 16 * H - 1, 16 * H, 10 * 365 days, 1, 5];
        for (uint256 i; i < dts.length; ++i) {
            if (i > 0) _next(dts[i]);
            (int24 s1, int24 e1, bool f1) = _anchor();
            assertFalse(f1, "before the first swap of the block");
            if (i == 0) assertEq(e1, s1, "first ever touch: ema = snapshot");
            if (i % 2 == 0) _buy(BIG_USDC);
            else _sell(BIG_MUMB);
            (int24 s2, int24 e2, bool f2) = _anchor();
            assertTrue(f2, "after");
            assertEq(s2, s1, "snapshot: view == stored");
            assertEq(e2, e1, "ema: view == stored");
            Raw memory r = _raw(idV2);
            assertEq(r.snap, s2);
            assertEq(AnchorLib.emaTick(r.emaX), e2);
            assertEq(r.blk, uint64(vm.getBlockNumber()));
            assertEq(r.ts, uint40(vm.getBlockTimestamp()));
            assertEq(r.high, 0, "unused bits stay zero");
        }
    }

    function test_V203_emaHalfLife() public {
        _halfLife(true);
        _halfLife(false);
    }

    function _halfLife(bool up) internal {
        uint256 snapState = vm.snapshotState();
        uint256 bn = vm.getBlockNumber();
        uint256 ts = vm.getBlockTimestamp();

        _buy(TINY_USDC);
        (int24 t0,,) = _anchor();
        if (up) _buy(BIG_USDC);
        else _sell(BIG_MUMB);
        int24 t1 = _tick(idV2);
        assertTrue(t1 != t0);
        int256 gap = int256(t1) - int256(t0);
        assertTrue(gap > 20 || gap < -20, "a real gap");

        _next(H);
        (int24 s, int24 e, bool f) = _anchor();
        assertFalse(f);
        assertEq(s, t1);
        int256 half = (int256(t0) + int256(t1)) / 2;
        int256 diff = int256(e) - half;
        assertLe(diff < 0 ? -diff : diff, 1, "covers half the gap, within 1 tick");
        assertTrue(vm.revertToState(snapState));
        vm.roll(bn);
        vm.warp(ts);
    }

    function test_V203_largeGapResets() public {
        _buy(TINY_USDC);
        (int24 t0,,) = _anchor();
        _buy(BIG_USDC);
        int24 t1 = _tick(idV2);
        assertTrue(t1 != t0);
        uint256 snapState = vm.snapshotState();
        uint256 bn = vm.getBlockNumber();
        uint256 ts = vm.getBlockTimestamp();

        uint256[3] memory dts = [16 * H - 1, 16 * H, uint256(1) << 39];
        for (uint256 i; i < dts.length; ++i) {
            _next(dts[i]);
            _buy(TINY_USDC);
            Raw memory r = _raw(idV2);
            assertEq(r.snap, t1);
            if (i == 0) assertTrue(r.emaX != int256(t1) * (1 << 16), "just under 16H: not reset");
            else assertEq(int256(r.emaX), int256(t1) * (1 << 16), "16H and beyond: ema = snapshot");
            assertTrue(vm.revertToState(snapState));
            vm.roll(bn);
            vm.warp(ts);
            snapState = vm.snapshotState();
        }
    }

    // ---------------------------------------------------------------- pool-only

    /// @dev Four swaps (exact in and out, both directions) across the first touch, the same block and the next
    ///      block. Returns every delta.
    function _sequence(PoolKey memory k) internal returns (int128[8] memory d) {
        BalanceDelta b;
        b = _swap(k, trader, usdcForMumb(), -int256(BIG_USDC), "");
        (d[0], d[1]) = (b.amount0(), b.amount1());
        b = _swap(k, trader, !usdcForMumb(), int256(300e6), "");
        (d[2], d[3]) = (b.amount0(), b.amount1());
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 3);
        b = _swap(k, trader, !usdcForMumb(), -int256(BIG_MUMB), "");
        (d[4], d[5]) = (b.amount0(), b.amount1());
        b = _swap(k, trader, usdcForMumb(), int256(200e18), "");
        (d[6], d[7]) = (b.amount0(), b.amount1());
    }

    function test_V203_poolOnlyUntilV207() public {
        uint256 snapState = vm.snapshotState();
        uint256 bn = vm.getBlockNumber();
        uint256 ts = vm.getBlockTimestamp();
        int128[8] memory withHook = _sequence(keyV2);
        assertTrue(vm.revertToState(snapState));
        vm.roll(bn);
        vm.warp(ts);
        int128[8] memory without = _sequence(plainKey);
        for (uint256 i; i < 8; ++i) {
            assertEq(withHook[i], without[i], "same delta as an unhooked pool");
        }
        assertTrue(withHook[0] != 0 && withHook[5] != 0);
        _assertHookNothing();

        // beforeSwap itself: zero delta, zero fee override; only the PoolManager may call it.
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: usdcForMumb(), amountSpecified: -int256(1e6), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        if (!usdcForMumb()) p.sqrtPriceLimitX96 = TickMath.MAX_SQRT_PRICE - 1;
        vm.expectRevert(ConfluenceHook.NotPoolManager.selector);
        hookV2.beforeSwap(address(this), keyV2, p, "");
        _next(1);
        vm.prank(POOL_MANAGER);
        (bytes4 sel, BeforeSwapDelta delta, uint24 fee) = hookV2.beforeSwap(address(this), keyV2, p, "");
        assertEq(sel, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0, "zero delta");
        assertEq(fee, 0, "no LP-fee override");
    }

    function _assertHookNothing() internal view {
        assertEq(mumb.balanceOf(address(hookV2)), 0);
        assertEq(IERC20Like(USDC).balanceOf(address(hookV2)), 0);
        assertEq(address(hookV2).balance, 0);
    }

    // ---------------------------------------------------------------- named risks

    function test_V203_sameTimestampNextBlock() public {
        _buy(TINY_USDC);
        _buy(BIG_USDC);
        _next(H); // a real gap so the EMA differs from the snapshot
        _buy(TINY_USDC);
        Raw memory a = _raw(idV2);
        assertTrue(int256(a.emaX) != int256(a.snap) * (1 << 16), "ema differs from the snapshot");
        // Next block, same timestamp: dt = 0.
        vm.roll(vm.getBlockNumber() + 1);
        (int24 s, int24 e, bool f) = _anchor();
        assertFalse(f);
        assertEq(s, _tick(idV2));
        _sell(BIG_MUMB);
        Raw memory b = _raw(idV2);
        assertEq(b.emaX, a.emaX, "dt = 0: ema unchanged to the unit");
        assertEq(b.snap, s, "the snapshot moved to the new block's");
        assertEq(b.blk, a.blk + 1);
        assertEq(b.ts, a.ts);
        (int24 s2, int24 e2, bool f2) = _anchor();
        assertTrue(f2);
        assertEq(s2, s);
        assertEq(e2, e);
    }

    function _initExtreme(uint24 fee, uint160 sqrtPrice) internal returns (PoolKey memory k, PoolId id) {
        (address c0, address c1) = sortedPair();
        k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, TICK_SPACING, IHooks(address(hookV2)));
        manager.initialize(k, sqrtPrice);
        id = k.toId();
    }

    function _touch(PoolKey memory k) internal {
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        vm.prank(POOL_MANAGER);
        hookV2.beforeSwap(address(this), k, p, "");
    }

    /// @dev Risk 4: the packed slot at MIN_TICK, the highest tick slot0 can hold, MAX_TICK itself, and the largest
    ///      timestamp and block number.
    function test_V203_packingRoundTrips() public {
        int24 maxTick = TickMath.MAX_TICK;
        int24 minTick = TickMath.MIN_TICK;
        vm.roll(type(uint64).max);
        vm.warp(type(uint40).max);

        // First touch at both ends of slot0's range.
        (PoolKey memory kMin, PoolId idMin) = _initExtreme(500, TickMath.MIN_SQRT_PRICE);
        (PoolKey memory kMax, PoolId idMax) = _initExtreme(10_000, TickMath.MAX_SQRT_PRICE - 1);
        _touch(kMin);
        _touch(kMax);
        Raw memory r = _raw(idMin);
        assertEq(r.snap, minTick, "MIN_TICK snapshot");
        assertEq(int256(r.emaX), int256(minTick) * (1 << 16), "MIN_TICK ema");
        assertEq(r.blk, type(uint64).max);
        assertEq(r.ts, type(uint40).max);
        assertEq(r.high, 0);
        (int24 s, int24 e, bool f) = hookV2.anchorOf(idMin);
        assertEq(s, minTick);
        assertEq(e, minTick);
        assertTrue(f);
        r = _raw(idMax);
        assertEq(r.snap, maxTick - 1, "highest tick slot0 can hold");
        assertEq(int256(r.emaX), int256(maxTick - 1) * (1 << 16));
        assertEq(r.high, 0);
        (s, e, f) = hookV2.anchorOf(idMax);
        assertEq(s, maxTick - 1);
        assertEq(e, maxTick - 1);

        // MAX_TICK itself (slot0 cannot hold it, the word can): written by hand, read back exactly.
        bytes32 word = _encode(type(uint40).max, type(uint64).max, maxTick, int56(int256(maxTick) * (1 << 16)));
        vm.store(address(hookV2), _slotOf(idMin), word);
        (s, e, f) = hookV2.anchorOf(idMin);
        assertEq(s, maxTick, "MAX_TICK read back");
        assertEq(e, maxTick);
        assertTrue(f);

        // Update over MAX_TICK in the largest block: stored one block earlier, timestamp wrapped so dt = H.
        vm.store(
            address(hookV2),
            _slotOf(idMin),
            _encode(type(uint40).max, type(uint64).max - 1, maxTick, int56(int256(maxTick) * (1 << 16)))
        );
        vm.warp(uint256(type(uint40).max) + 1 + H - 1);
        (s, e, f) = hookV2.anchorOf(idMin);
        assertEq(s, minTick, "lazy: the pool is at MIN_TICK");
        assertEq(e, 0, "dt = H over the whole range: the exact middle");
        assertFalse(f);
        _touch(kMin);
        r = _raw(idMin);
        assertEq(r.ts, uint40(H - 1), "timestamp wrapped");
        assertEq(r.blk, type(uint64).max);
        assertEq(r.snap, minTick);
        assertEq(r.emaX, 0, "exact: dev / 2");
        assertEq(r.high, 0);
    }

    function test_V203_anchorOfRevertsUninitialised() public {
        // A pool that was never initialised: tick 0 is a valid price, so zeros must not come back.
        (address c0, address c1) = sortedPair();
        PoolKey memory k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 100, TICK_SPACING, IHooks(address(hookV2)));
        vm.expectRevert(ConfluenceHook.PoolNotInitialized.selector);
        hookV2.anchorOf(k.toId());

        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        vm.prank(POOL_MANAGER);
        vm.expectRevert(ConfluenceHook.PoolNotInitialized.selector);
        hookV2.beforeSwap(address(this), k, p, "");

        // And it stays a revert for a pool whose anchor was stored this block only if the pool exists.
        assertEq(uint256(vm.load(address(hookV2), _slotOf(k.toId()))), 0, "nothing was stored");
    }
}

/// @dev Test-only. Repeats each step of the hook's anchor update on its own storage so each can be timed alone.
///      The mapping is at slot 0 and the struct is the hook's, so the SLOAD and SSTORE costs are the hook's.
contract AnchorGasProbe {
    using StateLibrary for IPoolManager;

    mapping(PoolId => AnchorLib.Anchor) internal _anchors;

    event AnchorUpdated(PoolId indexed poolId, int24 snapTick, int56 emaTickX, uint40 timestamp);

    struct Costs {
        uint256 empty; // two back-to-back gasleft() calls: the cost of measuring
        uint256 sload; // the struct to memory
        uint256 slot0; // StateLibrary.getSlot0 (an extsload call)
        uint256 next; // AnchorLib.next
        uint256 sstore; // the struct from memory
        uint256 log; // the event
    }

    function seed(PoolId id, AnchorLib.Anchor calldata a) external {
        _anchors[id] = a;
    }

    function run(IPoolManager m, PoolId id, uint256 ts, uint256 bn) external returns (Costs memory c) {
        uint256 g0 = gasleft();
        uint256 g1 = gasleft();
        c.empty = g0 - g1;

        g0 = gasleft();
        AnchorLib.Anchor memory a = _anchors[id];
        g1 = gasleft();
        c.sload = g0 - g1;

        g0 = gasleft();
        (, int24 tick,,) = m.getSlot0(id);
        g1 = gasleft();
        c.slot0 = g0 - g1;

        g0 = gasleft();
        a = AnchorLib.next(a, tick, ts, bn, 60);
        g1 = gasleft();
        c.next = g0 - g1;

        g0 = gasleft();
        _anchors[id] = a;
        g1 = gasleft();
        c.sstore = g0 - g1;

        g0 = gasleft();
        emit AnchorUpdated(id, a.snapTick, a.emaTickX, a.lastTimestamp);
        g1 = gasleft();
        c.log = g0 - g1;
    }
}

/// @notice V2-03 gas, measured the way the hook pays it: one swap through the PoolManager on the hooked pool against
/// the same swap on the unhooked twin, each from one snapshot, every account and slot made cold first (a swap is its
/// own transaction). Logged only; V2-11 sets budgets.
contract V203GasTest is PoolBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    ConfluenceHook internal hookV2;
    PoolKey internal keyV2;
    PoolKey internal plainKey;

    function setUp() public override {
        super.setUp();
        hookV2 = _deployHookV2();
        keyV2 = _createPool(IHooks(address(hookV2)));
        plainKey = _createPool(IHooks(address(0)));
        vm.startPrank(trader);
        mumb.approve(address(swapRouter), type(uint256).max);
        IERC20Like(USDC).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _cool() internal {
        vm.cool(POOL_MANAGER);
        vm.cool(address(swapRouter));
        vm.cool(USDC);
        vm.cool(address(mumb));
        vm.cool(address(hookV2));
    }

    /// @dev Gas of one exact-input USDC swap through the swap router, with everything cold.
    function _gasSwap(PoolKey memory k) internal returns (uint256 used) {
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: usdcForMumb(),
            amountSpecified: -int256(100e6),
            sqrtPriceLimitX96: usdcForMumb() ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        _cool();
        vm.prank(trader);
        uint256 g0 = gasleft();
        swapRouter.swap(k, p, PoolSwapTest.TestSettings(false, false), "");
        used = g0 - gasleft();
    }

    /// @dev swap 1 (first touch for the hooked pool), swap 2 (same block), swap 3 (next block, 12 s later).
    function _three(PoolKey memory k) internal returns (uint256[3] memory g) {
        uint256 snap = vm.snapshotState();
        uint256 bn = vm.getBlockNumber();
        uint256 ts = vm.getBlockTimestamp();
        g[0] = _gasSwap(k);
        g[1] = _gasSwap(k);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        g[2] = _gasSwap(k);
        assertTrue(vm.revertToState(snap));
        vm.roll(bn);
        vm.warp(ts);
    }

    function test_V203_gasInsideSwap() public {
        uint256[3] memory plain = _three(plainKey);
        uint256[3] memory hooked = _three(keyV2);
        console2.log("swap gas, plain pool  : first / same block / next block", plain[0], plain[1], plain[2]);
        console2.log("swap gas, hooked pool : first / same block / next block", hooked[0], hooked[1], hooked[2]);
        console2.log("hook cost, first-ever touch (zero slot -> anchor) ", hooked[0] - plain[0]);
        console2.log("hook cost, same block (anchor current, read only)  ", hooked[1] - plain[1]);
        console2.log("hook cost, new block (update of a stored anchor)   ", hooked[2] - plain[2]);
        assertGt(hooked[0], plain[0]);
        assertGt(hooked[2], hooked[1] - 1);
    }

    /// @dev Why a direct call from a test contract overstates the hook's cost: the same state-changing call to a probe
    ///      costs about 20,000 more when the test contract makes it than when a relay contract does. A swap through the
    ///      PoolManager (`test_V203_gasInsideSwap`) is the figure to use.
    function test_V203_gasCallOverhead() public {
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: usdcForMumb(),
            amountSpecified: -int256(1e6),
            sqrtPriceLimitX96: usdcForMumb() ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolKey memory k = keyV2; // copied before timing
        ConfluenceHook h = hookV2;
        // warm the hook and the anchor slot with one real update, then a same-block read-only call, key in memory.
        vm.prank(POOL_MANAGER);
        h.beforeSwap(address(this), k, p, "");
        uint256 g0 = gasleft();
        uint256 v = h.EMA_HALF_LIFE();
        console2.log("plain view call, no prank (EMA_HALF_LIFE)     ", g0 - gasleft(), v);
        vm.prank(POOL_MANAGER);
        g0 = gasleft();
        v = h.EMA_HALF_LIFE();
        console2.log("same view call under vm.prank                 ", g0 - gasleft(), v);
        vm.prank(POOL_MANAGER);
        g0 = gasleft();
        h.beforeSwap(address(this), k, p, "");
        console2.log("beforeSwap, same block, key already in memory ", g0 - gasleft());
        vm.prank(POOL_MANAGER);
        g0 = gasleft();
        h.beforeSwap(address(this), k, p, "");
        console2.log("  and again (identical)                       ", g0 - gasleft());
        g0 = gasleft();
        h.anchorOf(k.toId());
        console2.log("anchorOf (view), same block, stored path      ", g0 - gasleft());
        // The same read-only path with the real PoolManager as the caller of a contract-made call: a probe.
        AnchorGasProbe probe = new AnchorGasProbe();
        g0 = gasleft();
        probe.seed(k.toId(), AnchorLib.Anchor(1, 1, 1, 1));
        console2.log("probe.seed (one cold SSTORE zero->nonzero)    ", g0 - gasleft());
        SeedRelay relay = new SeedRelay();
        PoolId other = PoolId.wrap(bytes32(uint256(7)));
        console2.log("probe.seed via a relay contract (same SSTORE) ", relay.seed(probe, other));
        console2.log("probe.seed via a relay, slot already dirty    ", relay.seed(probe, other));
    }

    function test_V203_gasComponents() public {
        AnchorGasProbe probe = new AnchorGasProbe();
        PoolId id = keyV2.toId();
        uint256 ts = vm.getBlockTimestamp();
        uint256 bn = vm.getBlockNumber();
        // An anchor a block and 12 s old, so `next` runs the full path; and one with no anchor (first touch).
        probe.seed(id, AnchorLib.Anchor(uint40(ts - 12), uint64(bn - 1), 276_000, int56(276_000) * 65_536));
        _report("existing anchor, dt = 12", probe, id, ts, bn);
        // Worst case for exp2: dt = 59 of H = 60 sets most of the 32 fraction bits.
        probe.seed(id, AnchorLib.Anchor(uint40(ts - 59), uint64(bn - 1), 276_000, int56(276_000) * 65_536));
        _report("existing anchor, dt = 59 (most bits set)", probe, id, ts, bn);
        probe.seed(id, AnchorLib.Anchor(uint40(ts - 12), uint64(bn - 1), 276_000, int56(276_000) * 65_536));
        _reportFresh("first ever touch", probe, keyV2.toId(), ts, bn);
    }

    function _report(string memory what, AnchorGasProbe probe, PoolId id, uint256 ts, uint256 bn) internal {
        vm.cool(address(probe));
        vm.cool(POOL_MANAGER);
        AnchorGasProbe.Costs memory c = probe.run(IPoolManager(POOL_MANAGER), id, ts, bn);
        _log(what, c);
    }

    function _reportFresh(string memory what, AnchorGasProbe probe, PoolId id, uint256 ts, uint256 bn) internal {
        // A different id has an all-zero slot: SLOAD of zero, SSTORE zero -> non-zero.
        PoolId fresh = PoolId.wrap(keccak256(abi.encode(PoolId.unwrap(id), "fresh")));
        vm.cool(address(probe));
        vm.cool(POOL_MANAGER);
        // The fresh id has no slot0 on the manager (price 0, tick 0): the shape of the costs is what matters here.
        AnchorGasProbe.Costs memory c = probe.run(IPoolManager(POOL_MANAGER), fresh, ts, bn);
        _log(what, c);
    }

    function _log(string memory what, AnchorGasProbe.Costs memory c) internal pure {
        console2.log(what);
        console2.log("   measuring overhead (2 gasleft)", c.empty);
        console2.log("   SLOAD of the packed anchor    ", c.sload);
        console2.log("   getSlot0 (extsload, cold)     ", c.slot0);
        console2.log("   AnchorLib.next                ", c.next);
        console2.log("   SSTORE of the anchor          ", c.sstore);
        console2.log("   AnchorUpdated event           ", c.log);
    }
}

contract SeedRelay {
    function seed(AnchorGasProbe probe, PoolId id) external returns (uint256) {
        uint256 g0 = gasleft();
        probe.seed(id, AnchorLib.Anchor(1, 1, 1, 1));
        return g0 - gasleft();
    }
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}
