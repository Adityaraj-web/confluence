// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";

import {
    BandGuardV2,
    InvalidArgsLength,
    InvalidBand,
    InvalidDrift,
    InvalidFlags,
    PoolTokenMismatch,
    TakerNotHook,
    AnchorDrift,
    BandNotComputed,
    BandExceeded
} from "../../src/BandGuardV2.sol";
import {ConfluenceHook} from "../../src/ConfluenceHook.sol";

/// @notice Answers `anchorOfX` for one pool id and reverts `PoolNotInitialized` for any other, as the real hook does
///         for a pool with no price. A guard that derives the wrong pool id therefore reverts.
contract MockAnchorHook {
    PoolId internal knownId;
    int24 internal snap;
    int56 internal emaX;

    function set(PoolId id, int24 snapTick, int56 emaTickX) external {
        knownId = id;
        snap = snapTick;
        emaX = emaTickX;
    }

    function anchorOfX(PoolId id) external view returns (int24, int56, bool) {
        if (PoolId.unwrap(id) != PoolId.unwrap(knownId)) revert ConfluenceHook.PoolNotInitialized();
        return (snap, emaX, true);
    }
}

/// @notice V2-04: BandGuardV2's args, checks and price maths, with no fork and no router.
contract V204BandGuardTest is Test {
    using PoolIdLibrary for PoolKey;

    int256 internal constant UNIT = 2 ** 16; // one tick in the EMA's fixed point
    uint16 internal constant BAND = 200;
    uint16 internal constant DRIFT = 300;
    uint256 internal constant NEXT_PC = 123;
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant Q192 = 2 ** 192;

    address internal constant PM = address(0x9999);
    address internal constant TOKEN0 = address(0x1000);
    address internal constant TOKEN1 = address(0x2000);
    address internal constant OTHER = address(0x3000);
    address internal constant TAKER = address(0xBEEF);
    /// @dev Every key field is non-zero and unlike the fork pools, so none can be assumed.
    uint24 internal constant LP_FEE = 500;
    int24 internal constant SPACING = 10;

    BandGuardV2 internal guard;
    MockAnchorHook internal mock;
    PoolKey internal key;
    PoolId internal id;

    function setUp() public {
        guard = new BandGuardV2();
        mock = new MockAnchorHook();
        key = PoolKey(Currency.wrap(TOKEN0), Currency.wrap(TOKEN1), LP_FEE, SPACING, IHooks(address(mock)));
        id = key.toId();
        _anchor(0, 0);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev The anchor with the EMA exactly on the snapshot.
    function _anchor(int24 snap, int56 emaX) internal {
        mock.set(id, snap, emaX);
    }

    function _flat(int24 snap) internal {
        _anchor(snap, int56(int256(snap) * UNIT));
    }

    /// @dev Hand-packed, so a broken `build` cannot hide behind these fixtures.
    function _pack(uint16 bandBps, uint16 driftTicks, uint8 flags) internal view returns (bytes memory) {
        return abi.encodePacked(PM, TOKEN0, TOKEN1, LP_FEE, SPACING, address(mock), bandBps, driftTicks, flags);
    }

    function _args(uint16 bandBps) internal view returns (bytes memory) {
        return _pack(bandBps, DRIFT, 0);
    }

    function _run(address taker, address tokenIn, uint256 amountIn, uint256 amountOut, bytes memory args, bool isStatic)
        internal
        view
        returns (uint256, uint256, SwapRegisters memory)
    {
        address tokenOut = tokenIn == TOKEN0 ? TOKEN1 : TOKEN0;
        SwapQuery memory q = SwapQuery(bytes32(uint256(1)), address(1), taker, tokenIn, tokenOut, true);
        SwapRegisters memory r = SwapRegisters(11, 22, amountIn, amountOut, 33);
        return guard.extruction(isStatic, NEXT_PC, q, r, args, hex"abcd");
    }

    function _assertPasses(address taker, address tokenIn, uint256 amountIn, uint256 amountOut, bytes memory args)
        internal
        view
    {
        bool[2] memory contexts = [false, true];
        for (uint256 i = 0; i < 2; i++) {
            (uint256 nextPC, uint256 chopped, SwapRegisters memory r) =
                _run(taker, tokenIn, amountIn, amountOut, args, contexts[i]);
            assertEq(nextPC, NEXT_PC, "nextPC changed");
            assertEq(chopped, 0, "taker data consumed");
            assertEq(r.balanceIn, 11, "balanceIn changed");
            assertEq(r.balanceOut, 22, "balanceOut changed");
            assertEq(r.amountIn, amountIn, "amountIn changed");
            assertEq(r.amountOut, amountOut, "amountOut changed");
            assertEq(r.amountNetPulled, 33, "amountNetPulled changed");
        }
    }

    /// @dev The oracle for the guard's price scale: (ref, unit) such that a fill with `exec = ref` is
    ///      (amountIn, amountOut) = (unit, ref) for currency0 in and (ref, unit) for currency1 in.
    ///      Below sqrt 2^127 the scale is X192 (exact `s^2`), above it X96.
    function _ref(int24 tick) internal pure returns (uint256 ref, uint256 unit) {
        uint256 s = TickMath.getSqrtPriceAtTick(tick);
        if (s < 2 ** 127) return (s * s, Q192);
        return (FullMath.mulDiv(s, s, Q96), Q96);
    }

    /// @dev Registers of a fill whose execution price (currency1 per currency0, in the guard's scale) is `exec`.
    function _regs(address tokenIn, uint256 exec, uint256 unit) internal pure returns (uint256 amountIn, uint256 amountOut) {
        return tokenIn == TOKEN0 ? (unit, exec) : (exec, unit);
    }

    function _expectExceeded(uint256 exec, uint256 ref, uint16 band) internal {
        vm.expectRevert(abi.encodeWithSelector(BandExceeded.selector, exec, ref, band));
    }

    // ---------------------------------------------------------------- args

    function test_V204_argsRoundTrip() public view {
        _assertRoundTrip(PM, key, BAND, DRIFT, 1);
        _assertRoundTrip(PM, key, 1, 0, 0);
        _assertRoundTrip(PM, key, 10_000, 10_000, 1);
    }

    function testFuzz_V204_argsRoundTrip(
        address manager,
        address c0,
        address c1,
        uint24 fee,
        int24 spacing,
        address hooks,
        uint16 band,
        uint16 drift,
        uint8 flags
    ) public view {
        band = uint16(bound(band, 1, 10_000));
        drift = uint16(bound(drift, 0, 10_000));
        flags = uint8(bound(flags, 0, 1));
        PoolKey memory k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, IHooks(hooks));
        _assertRoundTrip(manager, k, band, drift, flags);
    }

    function _assertRoundTrip(address manager, PoolKey memory k, uint16 band, uint16 drift, uint8 flags) internal view {
        bytes memory args = guard.build(IPoolManager(manager), k, band, drift, flags);
        assertEq(args.length, 91, "args length");
        assertEq(
            args,
            abi.encodePacked(manager, k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks, band, drift, flags),
            "args layout"
        );
        (IPoolManager m, PoolKey memory p, uint16 b, uint16 d, uint8 f) = guard.parse(args);
        assertEq(address(m), manager, "manager");
        assertEq(Currency.unwrap(p.currency0), Currency.unwrap(k.currency0), "currency0");
        assertEq(Currency.unwrap(p.currency1), Currency.unwrap(k.currency1), "currency1");
        assertEq(p.fee, k.fee, "fee");
        assertEq(p.tickSpacing, k.tickSpacing, "tickSpacing");
        assertEq(address(p.hooks), address(k.hooks), "hooks");
        assertEq(b, band, "band");
        assertEq(d, drift, "drift");
        assertEq(f, flags, "flags");
    }

    function _slice(bytes memory data, uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            out[i] = data[i];
        }
    }

    /// @dev Each bad value through `build` (where it can be built), `parse` and the check itself.
    function _expectBadArgs(bytes memory expected, bytes memory args) internal {
        vm.expectRevert(expected);
        guard.parse(args);
        vm.expectRevert(expected);
        _run(TAKER, TOKEN0, Q96, Q96, args, false);
    }

    function test_V204_badArgsRevert() public {
        bytes memory good = _args(BAND);
        // Length: empty, 88 (v1's), 90, 92.
        uint256[4] memory lengths = [uint256(0), 88, 90, 92];
        for (uint256 i = 0; i < lengths.length; i++) {
            bytes memory bad = lengths[i] <= 91 ? _slice(good, lengths[i]) : bytes.concat(good, hex"00");
            _expectBadArgs(abi.encodeWithSelector(InvalidArgsLength.selector, lengths[i]), bad);
        }
        // Band 0 and above the limit.
        uint16[2] memory bands = [uint16(0), 10_001];
        for (uint256 i = 0; i < bands.length; i++) {
            vm.expectRevert(InvalidBand.selector);
            guard.build(IPoolManager(PM), key, bands[i], DRIFT, 0);
            _expectBadArgs(abi.encodeWithSelector(InvalidBand.selector), _pack(bands[i], DRIFT, 0));
        }
        // Drift above the limit.
        vm.expectRevert(InvalidDrift.selector);
        guard.build(IPoolManager(PM), key, BAND, 10_001, 0);
        _expectBadArgs(abi.encodeWithSelector(InvalidDrift.selector), _pack(BAND, 10_001, 0));
        vm.expectRevert(InvalidDrift.selector);
        guard.build(IPoolManager(PM), key, BAND, type(uint16).max, 0);
        // Unknown flag bits.
        uint8[4] memory flagsBad = [uint8(2), 3, 0x80, 0xFF];
        for (uint256 i = 0; i < flagsBad.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(InvalidFlags.selector, flagsBad[i]));
            guard.build(IPoolManager(PM), key, BAND, DRIFT, flagsBad[i]);
            _expectBadArgs(abi.encodeWithSelector(InvalidFlags.selector, flagsBad[i]), _pack(BAND, DRIFT, flagsBad[i]));
        }
        // The ends of every range are valid.
        _flat(0);
        _assertPasses(TAKER, TOKEN0, Q96, Q96, _pack(1, 0, 0));
        _assertPasses(TAKER, TOKEN0, Q96, Q96, _pack(10_000, 10_000, 0));
    }

    // ---------------------------------------------------------------- taker

    function test_V204_exclusiveRefusesOtherTakers() public {
        _flat(0);
        bytes memory args = _pack(BAND, DRIFT, 1);
        bool[2] memory contexts = [false, true];
        for (uint256 i = 0; i < 2; i++) {
            // Only the key's hook passes, in swap and in quote.
            (uint256 nextPC,,) = _run(address(mock), TOKEN0, Q96, Q96, args, contexts[i]);
            assertEq(nextPC, NEXT_PC);
            address[3] memory others = [TAKER, address(this), address(0)];
            for (uint256 j = 0; j < others.length; j++) {
                vm.expectRevert(abi.encodeWithSelector(TakerNotHook.selector, others[j]));
                _run(others[j], TOKEN0, Q96, Q96, args, contexts[i]);
            }
        }
    }

    function test_V204_openAllowsAnyTaker() public {
        _flat(0);
        bytes memory args = _pack(BAND, DRIFT, 0);
        address[4] memory takers = [TAKER, address(this), address(0), address(mock)];
        for (uint256 i = 0; i < takers.length; i++) {
            _assertPasses(takers[i], TOKEN0, Q96, Q96, args);
        }
    }

    // ---------------------------------------------------------------- drift

    function test_V204_driftRefusal() public {
        int24 snap = 100;
        uint16 d = 5;
        bytes memory args = _pack(BAND, d, 0);
        (uint256 ref, uint256 unit) = _ref(snap);
        (uint256 amountIn, uint256 amountOut) = _regs(TOKEN0, ref, unit);
        int56 base = int56(int256(snap) * UNIT);
        int56 limit = int56(int256(uint256(d)) * UNIT);

        // At the limit exactly, below and above the snapshot: passes.
        _anchor(snap, base - limit);
        _assertPasses(TAKER, TOKEN0, amountIn, amountOut, args);
        _anchor(snap, base + limit);
        _assertPasses(TAKER, TOKEN0, amountIn, amountOut, args);
        // One fixed-point unit past it: refused.
        _anchor(snap, base - limit - 1);
        vm.expectRevert(abi.encodeWithSelector(AnchorDrift.selector, snap, base - limit - 1, d));
        _run(TAKER, TOKEN0, amountIn, amountOut, args, false);
        _anchor(snap, base + limit + 1);
        vm.expectRevert(abi.encodeWithSelector(AnchorDrift.selector, snap, base + limit + 1, d));
        _run(TAKER, TOKEN0, amountIn, amountOut, args, true);

        // Rounding never decides: this EMA rounds to snap - 5 (within the limit) but is 20,000 units further.
        int56 rounds = base - limit - 20_000;
        assertEq((rounds + int56(UNIT / 2)) >> 16, int56(snap) - int56(uint56(d)), "premise: rounds to the limit");
        _anchor(snap, rounds);
        vm.expectRevert(abi.encodeWithSelector(AnchorDrift.selector, snap, rounds, d));
        _run(TAKER, TOKEN0, amountIn, amountOut, args, false);

        // driftTicks = 0: the EMA must equal the snapshot.
        bytes memory zero = _pack(BAND, 0, 0);
        _anchor(snap, base);
        _assertPasses(TAKER, TOKEN0, amountIn, amountOut, zero);
        _anchor(snap, base + 1);
        vm.expectRevert(abi.encodeWithSelector(AnchorDrift.selector, snap, base + 1, uint16(0)));
        _run(TAKER, TOKEN0, amountIn, amountOut, zero, false);
    }

    // ---------------------------------------------------------------- band: direction, order, edges

    /// @dev Only the swap's direction flips: the outcome must flip with it.
    function test_V204_directionFlipFlipsOutcome() public {
        _flat(953); // price about 1.09998
        bytes memory args = _args(BAND);
        uint256 a = 1e18;
        uint256 b = 1.1e18;
        // currency0 in: exec = b / a = 1.1.  Passes.
        _assertPasses(TAKER, TOKEN0, a, b, args);
        // Same registers, currency1 in: exec = a / b = 0.909.  Refused, with the inverse price.
        (uint256 ref,) = _ref(953);
        _expectExceeded(FullMath.mulDiv(a, Q192, b), ref, BAND);
        _run(TAKER, TOKEN1, a, b, args, false);
        // And the other way round.
        _assertPasses(TAKER, TOKEN1, b, a, args);
        _expectExceeded(FullMath.mulDiv(a, Q192, b), ref, BAND);
        _run(TAKER, TOKEN0, b, a, args, true);
    }

    /// @dev One economic fill, A for B at 1.1: with A as currency0 (snapshot +953) or as currency1 (snapshot -953).
    function test_V204_currencyOrderInvariant() public {
        bytes memory args = _args(BAND);
        // A is currency0.
        _flat(953);
        _assertPasses(TAKER, TOKEN0, 1e18, 1.1e18, args);
        // A is currency1: the same fill reads as currency1 in, and the snapshot is mirrored.
        _flat(-953);
        _assertPasses(TAKER, TOKEN1, 1e18, 1.1e18, args);
        // Out of band by the same amount in both orders.
        _flat(953);
        vm.expectPartialRevert(BandExceeded.selector);
        _run(TAKER, TOKEN0, 1e18, 1.2e18, args, false);
        _flat(-953);
        vm.expectPartialRevert(BandExceeded.selector);
        _run(TAKER, TOKEN1, 1e18, 1.2e18, args, false);
    }

    /// @dev F03's unit cases with the snapshot as the reference.
    function test_V204_v1BandCasesHold() public {
        _flat(0);
        uint16[2] memory bands = [BAND, 50];
        for (uint256 i = 0; i < 2; i++) {
            bytes memory args = _args(bands[i]);
            uint256 limit = FullMath.mulDiv(Q192, bands[i], 10_000);
            address[2] memory ins = [TOKEN0, TOKEN1];
            for (uint256 j = 0; j < 2; j++) {
                (uint256 inA, uint256 outA) = _regs(ins[j], Q192, Q192);
                _assertPasses(TAKER, ins[j], inA, outA, args);
                (inA, outA) = _regs(ins[j], Q192 + limit, Q192);
                _assertPasses(TAKER, ins[j], inA, outA, args);
                (inA, outA) = _regs(ins[j], Q192 - limit, Q192);
                _assertPasses(TAKER, ins[j], inA, outA, args);
                (inA, outA) = _regs(ins[j], Q192 + limit + 1, Q192);
                _expectExceeded(Q192 + limit + 1, Q192, bands[i]);
                _run(TAKER, ins[j], inA, outA, args, false);
                (inA, outA) = _regs(ins[j], Q192 - limit - 1, Q192);
                _expectExceeded(Q192 - limit - 1, Q192, bands[i]);
                _run(TAKER, ins[j], inA, outA, args, true);
            }
        }
        bytes memory a = _args(BAND);
        // Zero registers, both orientations.
        address[2] memory dirs = [TOKEN0, TOKEN1];
        for (uint256 i = 0; i < 2; i++) {
            vm.expectRevert(BandNotComputed.selector);
            _run(TAKER, dirs[i], Q96, 0, a, false);
            vm.expectRevert(BandNotComputed.selector);
            _run(TAKER, dirs[i], 0, Q96, a, false);
        }
        // Token mismatch.
        address[6] memory ins2 = [OTHER, TOKEN0, OTHER, TOKEN1, TOKEN0, TOKEN1];
        address[6] memory outs2 = [TOKEN1, OTHER, TOKEN0, OTHER, TOKEN0, TOKEN1];
        for (uint256 i = 0; i < 6; i++) {
            vm.expectRevert(PoolTokenMismatch.selector);
            guard.extruction(
                false,
                NEXT_PC,
                SwapQuery(bytes32(0), address(1), TAKER, ins2[i], outs2[i], true),
                SwapRegisters(0, 0, Q96, Q96, 0),
                a,
                ""
            );
        }
        // Every key field is part of the pool id: a changed field names a pool the hook does not know.
        bytes memory otherFee = abi.encodePacked(PM, TOKEN0, TOKEN1, LP_FEE + 1, SPACING, address(mock), BAND, DRIFT, uint8(0));
        bytes memory otherSpacing =
            abi.encodePacked(PM, TOKEN0, TOKEN1, LP_FEE, SPACING + 1, address(mock), BAND, DRIFT, uint8(0));
        bytes[2] memory others = [otherFee, otherSpacing];
        for (uint256 i = 0; i < 2; i++) {
            vm.expectRevert(ConfluenceHook.PoolNotInitialized.selector);
            _run(TAKER, TOKEN0, Q96, Q96, others[i], false);
        }
        // A wrong hook with no code refuses too: the guard never falls back to spot.
        bytes memory noHook = abi.encodePacked(PM, TOKEN0, TOKEN1, LP_FEE, SPACING, address(0), BAND, DRIFT, uint8(0));
        vm.expectRevert();
        _run(TAKER, TOKEN0, Q96, Q96, noHook, false);
    }

    /// @dev The case v1's X96 refuses: at the ends of the tick range the exact reference price must pass with
    ///      `bandBps` = 1, in both directions, in swap and in quote.
    function test_V204_exactFillPassesAtBandOneNearTickBounds() public {
        int24[2] memory ticks = [TickMath.MIN_TICK + 1, TickMath.MAX_TICK - 1];
        bytes memory args = _pack(1, DRIFT, 0);
        for (uint256 i = 0; i < 2; i++) {
            _flat(ticks[i]);
            (uint256 ref, uint256 unit) = _ref(ticks[i]);
            assertGt(ref, 0, "reference is zero");
            address[2] memory dirs = [TOKEN0, TOKEN1];
            for (uint256 j = 0; j < 2; j++) {
                (uint256 amountIn, uint256 amountOut) = _regs(dirs[j], ref, unit);
                _assertPasses(TAKER, dirs[j], amountIn, amountOut, args);
            }
        }
        // v1's X96 reference at MIN_TICK + 1 is zero: it would refuse every fill.
        uint256 s = TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK + 1);
        assertEq(FullMath.mulDiv(s, s, Q96), 0, "premise: X96 rounds to zero");
    }

    function _switchTick() internal pure returns (int24 lo) {
        // The first tick whose sqrt price is at least 2^127.
        int24 a = 0;
        int24 b = TickMath.MAX_TICK;
        while (a < b) {
            int24 m = a + (b - a) / 2;
            if (TickMath.getSqrtPriceAtTick(m) >= 2 ** 127) b = m;
            else a = m + 1;
        }
        return a;
    }

    /// @dev Exact edge of the band at the extremes of the tick range, both scales, both directions, three widths.
    function test_V204_priceEdges() public {
        int24 sw = _switchTick();
        int24[9] memory ticks = [
            TickMath.MIN_TICK,
            TickMath.MIN_TICK + 1,
            int24(-1),
            int24(0),
            int24(1),
            sw - 1,
            sw,
            TickMath.MAX_TICK - 1,
            TickMath.MAX_TICK
        ];
        uint16[3] memory bands = [uint16(1), BAND, 10_000];
        address[2] memory dirs = [TOKEN0, TOKEN1];
        for (uint256 t = 0; t < ticks.length; t++) {
            _flat(ticks[t]);
            (uint256 ref, uint256 unit) = _ref(ticks[t]);
            for (uint256 b = 0; b < bands.length; b++) {
                bytes memory args = _pack(bands[b], DRIFT, 0);
                uint256 limit = FullMath.mulDiv(ref, bands[b], 10_000);
                for (uint256 d = 0; d < 2; d++) {
                    uint256 x;
                    uint256 y;
                    (x, y) = _regs(dirs[d], ref, unit);
                    _assertPasses(TAKER, dirs[d], x, y, args);
                    (x, y) = _regs(dirs[d], ref + limit, unit);
                    _assertPasses(TAKER, dirs[d], x, y, args);
                    (x, y) = _regs(dirs[d], ref + limit + 1, unit);
                    _expectExceeded(ref + limit + 1, ref, bands[b]);
                    _run(TAKER, dirs[d], x, y, args, false);
                    if (ref > limit + 1) {
                        (x, y) = _regs(dirs[d], ref - limit, unit);
                        _assertPasses(TAKER, dirs[d], x, y, args);
                        (x, y) = _regs(dirs[d], ref - limit - 1, unit);
                        _expectExceeded(ref - limit - 1, ref, bands[b]);
                        _run(TAKER, dirs[d], x, y, args, true);
                    }
                }
            }
        }
    }

    /// @dev An execution price at or beyond 2^256 is refused by name with the saturated value, never a panic.
    function test_V204_saturatingPrice() public {
        int24[2] memory ticks = [int24(0), TickMath.MAX_TICK - 1];
        for (uint256 i = 0; i < 2; i++) {
            _flat(ticks[i]);
            (uint256 ref,) = _ref(ticks[i]);
            bytes memory args = _args(BAND);
            _expectExceeded(type(uint256).max, ref, BAND);
            _run(TAKER, TOKEN0, 1, type(uint256).max, args, false);
            _expectExceeded(type(uint256).max, ref, BAND);
            _run(TAKER, TOKEN1, type(uint256).max, 1, args, true);
        }
        // Both registers at the maximum: price exactly 1.
        _flat(0);
        _assertPasses(TAKER, TOKEN0, type(uint256).max, type(uint256).max, _args(BAND));
    }

    function testFuzz_V204_neverPanics(int256 tick, uint256 amountIn, uint256 amountOut, uint16 band, bool token0In)
        public
    {
        int24 t = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK));
        amountIn = bound(amountIn, 1, type(uint256).max);
        amountOut = bound(amountOut, 1, type(uint256).max);
        band = uint16(bound(band, 1, 10_000));
        _flat(t);
        try this.runExternal(token0In ? TOKEN0 : TOKEN1, amountIn, amountOut, _args(band)) {}
        catch (bytes memory reason) {
            assertEq(bytes4(reason), BandExceeded.selector, "only the band may refuse");
        }
    }

    /// @dev `try` needs an external call.
    function runExternal(address tokenIn, uint256 amountIn, uint256 amountOut, bytes memory args) external view {
        _run(TAKER, tokenIn, amountIn, amountOut, args, false);
    }
}
