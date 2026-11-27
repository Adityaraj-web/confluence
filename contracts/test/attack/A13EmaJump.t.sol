// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";

import {BandGuardV2} from "../../src/BandGuardV2.sol";
import {AnchorLib} from "../../src/libraries/AnchorLib.sol";
import {MakerVenue} from "../../src/libraries/MakerVenue.sol";
import {MockAnchorHook} from "../unit/V204BandGuard.t.sol";

/// @notice V2-10 (carry-over from V2-03, D-31): the EMA's cut-off jump. `AnchorLib.decayX128` returns 0 from `dt >= 16
///         half-lives`, so the EMA jumps from `snap + gap * 2^-15.98` to exactly `snap` between `dt = 16H - 1` and `16H`.
///         At the full tick range (a gap of 1,774,544 ticks) that is about 27 ticks. This file measures it, bounds it
///         over the whole range with 50,000 runs, and shows what it can and cannot change for a maker's guard:
///         only the DRIFT decision (and only for `driftTicks` below the residual), never the band, whose reference is the
///         snapshot.
contract A13EmaJumpTest is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant PM = address(0x9999);
    address internal constant TOKEN0 = address(0x1000);
    address internal constant TOKEN1 = address(0x2000);
    uint24 internal constant LP_FEE = 500;
    int24 internal constant SPACING = 10;
    int256 internal constant UNIT = 2 ** 16;
    uint256 internal constant H = 60; // the hook's EMA_HALF_LIFE
    uint256 internal constant CUT = 16 * H;

    BandGuardV2 internal guard;
    MockAnchorHook internal mock;
    PoolKey internal key;
    PoolId internal id;

    function setUp() public {
        guard = new BandGuardV2();
        mock = new MockAnchorHook();
        key = PoolKey(Currency.wrap(TOKEN0), Currency.wrap(TOKEN1), LP_FEE, SPACING, IHooks(address(mock)));
        id = key.toId();
    }

    function _abs(int256 v) internal pure returns (uint256) {
        return uint256(v < 0 ? -v : v);
    }

    /// @dev The EMA the hook stores after an update `dt` seconds later: a flat anchor at `oldSnap`, then `snap`.
    function _ema(int24 oldSnap, int24 snap, uint256 dt) internal pure returns (int56) {
        return AnchorLib.nextEmaX(int256(oldSnap) * UNIT, snap, dt, H);
    }

    function _residualX(int24 snap, int56 emaX) internal pure returns (uint256) {
        return _abs(int256(snap) * UNIT - int256(emaX));
    }

    // ---------------------------------------------------------------- the measured jump

    /// @dev Full range: the old anchor at the bottom tick, a swap at the top tick, `dt` just under and at the cut-off.
    function test_V210_emaCutoffJumpAtFullRange() public {
        int24 lo = TickMath.MIN_TICK;
        int24 hi = TickMath.MAX_TICK;
        uint256 gap = uint256(int256(hi) - int256(lo));
        uint256 before = _residualX(hi, _ema(lo, hi, CUT - 1));
        uint256 at = _residualX(hi, _ema(lo, hi, CUT));
        emit log_named_uint("full-range gap (ticks)", gap);
        emit log_named_uint("residual at 16H - 1, in ticks x 1000", before * 1000 / uint256(UNIT));
        emit log_named_uint("residual at 16H (X units)", at);
        assertEq(at, 0, "from 16 half-lives the EMA is exactly the snapshot");
        assertGt(before, 0, "just before the cut-off the EMA still trails");
        // The cut-off jump: a gap of 1,774,544 ticks times 2^-15.98 is 27.4 ticks.
        assertLe(before, 28 * uint256(UNIT), "the jump is at most 28 ticks at the full range");
        assertGe(before, 27 * uint256(UNIT), "and it is about 27 ticks: the measurement is not vacuous");
    }

    /// @dev Over the whole range, the residual one second before the cut-off is bounded by `gap * 2^(1/60) / 2^16` (in
    ///      tick-x-2^16 units: `gap * 1.0117 + 2`), and from the cut-off on the EMA is exactly the snapshot.
    /// forge-config: default.fuzz.runs = 50000
    function testFuzz_V210_emaJumpIsBounded(int24 oldSeed, int24 snapSeed, uint16 pastCut) public pure {
        int24 oldSnap = int24(bound(int256(oldSeed), TickMath.MIN_TICK, TickMath.MAX_TICK));
        int24 snap = int24(bound(int256(snapSeed), TickMath.MIN_TICK, TickMath.MAX_TICK));
        uint256 gap = _abs(int256(snap) - int256(oldSnap));
        uint256 before = _residualX(snap, _ema(oldSnap, snap, CUT - 1));
        assertLe(before, gap * 10_117 / 10_000 + 2, "the residual just before the cut-off exceeds gap * 2^(1/60-16)");
        assertEq(_ema(oldSnap, snap, CUT), int56(int256(snap) * UNIT), "at the cut-off the EMA is the snapshot");
        assertEq(_ema(oldSnap, snap, CUT + uint256(pastCut)), int56(int256(snap) * UNIT), "and stays there");
        // The EMA moves monotonically toward the snapshot: later is never farther.
        assertLe(before, _residualX(snap, _ema(oldSnap, snap, CUT - 61)), "later is not farther");
    }

    /// @dev The snapshot is the band's reference and it does not depend on `dt` or the EMA: `AnchorLib.next` stores
    ///      the slot tick whatever the elapsed time.
    /// forge-config: default.fuzz.runs = 50000
    function testFuzz_V210_snapshotIgnoresDt(int24 oldSeed, int24 snapSeed, uint256 dtSeed) public pure {
        int24 oldSnap = int24(bound(int256(oldSeed), TickMath.MIN_TICK, TickMath.MAX_TICK));
        int24 snap = int24(bound(int256(snapSeed), TickMath.MIN_TICK, TickMath.MAX_TICK));
        uint256 dt = bound(dtSeed, 1, 2 * CUT);
        AnchorLib.Anchor memory a = AnchorLib.Anchor(1_000, 7, oldSnap, int56(int256(oldSnap) * UNIT));
        AnchorLib.Anchor memory n = AnchorLib.next(a, snap, 1_000 + dt, 8, H);
        assertEq(n.snapTick, snap, "the snapshot is the slot tick at any dt");
    }

    // ---------------------------------------------------------------- what the jump changes for a maker's guard

    function _pack(uint16 bandBps, uint16 driftTicks) internal view returns (bytes memory) {
        return abi.encodePacked(PM, TOKEN0, TOKEN1, LP_FEE, SPACING, address(mock), bandBps, driftTicks, uint8(0));
    }

    function _guard(int24 snap, int56 emaX, uint16 bandBps, uint16 driftTicks, uint256 net, uint256 out)
        internal
        returns (bool)
    {
        mock.set(id, snap, emaX);
        SwapQuery memory q = SwapQuery(bytes32(uint256(1)), address(1), address(0xBEEF), TOKEN0, TOKEN1, true);
        SwapRegisters memory r = SwapRegisters(11, 22, net, out, 0);
        try guard.extruction(true, 0, q, r, _pack(bandBps, driftTicks), "") returns (
            uint256, uint256, SwapRegisters memory
        ) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev A token0-in fill at execution price `execT` (X192 scale) for net input `net`.
    function _fill(int24 snap, uint256 execT) internal pure returns (uint256 net, uint256 out) {
        net = 1e24;
        out = FullMath.mulDiv(net, execT, 2 ** 192);
        snap; // the price is given by the caller
    }

    /// @dev With `driftTicks` in {0, 10, 26, 27, 300, 10000}: one second either side of the cut-off, the drift decision
    ///      (the library mirror and the real guard) differs only when `driftTicks` is below the residual, which is under
    ///      28 ticks; a fill outside the band is refused at BOTH EMAs for every `driftTicks`; a fill at the snapshot
    ///      price passes exactly when the drift does.
    /// forge-config: default.fuzz.runs = 50000
    function testFuzz_V210_cutoffChangesOnlyTheDriftDecision(
        int24 oldSeed,
        int24 snapSeed,
        uint256 driftPick,
        uint16 bpsSeed
    ) public {
        int24 snap = int24(bound(int256(snapSeed), -300_000, 300_000)); // X192 scale: the band is exercised below
        int24 oldSnap = int24(bound(int256(oldSeed), TickMath.MIN_TICK, TickMath.MAX_TICK));
        uint16[6] memory drifts = [uint16(0), 10, 26, 27, 300, 10_000];
        uint16 drift = drifts[driftPick % 6];
        uint16 bps = uint16(bound(bpsSeed, 1, 10_000));
        int56 emaBefore = _ema(oldSnap, snap, CUT - 1);
        int56 emaAfter = _ema(oldSnap, snap, CUT);
        uint256 residual = _residualX(snap, emaBefore);

        // 1. The library mirror and the real guard agree with the arithmetic, on both sides of the cut-off.
        bool driftBefore = MakerVenue.driftPasses(snap, emaBefore, drift);
        bool driftAfter = MakerVenue.driftPasses(snap, emaAfter, drift);
        assertTrue(driftAfter, "at the cut-off the EMA is the snapshot: drift always passes");
        assertEq(driftBefore, residual <= uint256(drift) * uint256(UNIT), "drift is the residual against the limit");
        if (!driftBefore) {
            assertLt(uint256(drift) * uint256(UNIT), residual, "a refusal means the limit is below the residual");
            assertLt(drift, 28, "and only a limit under the 28-tick jump can be affected");
        }

        // 2. A fill AT the snapshot price passes the real guard exactly when the drift passes.
        uint256 s = TickMath.getSqrtPriceAtTick(snap);
        uint256 ref = s * s; // X192 scale for |tick| <= 300,000
        (uint256 net, uint256 out) = _fill(snap, ref);
        assertEq(_guard(snap, emaBefore, bps, drift, net, out), driftBefore, "guard at 16H-1: the drift decides");
        assertTrue(_guard(snap, emaAfter, bps, drift, net, out), "guard at 16H: passes");

        // 3. A fill outside the band (price above the upper edge by 1% of the price) is refused at BOTH EMAs.
        uint256 lim = FullMath.mulDiv(ref, bps, 10_000);
        (net, out) = _fill(snap, ref + lim + ref / 100 + 1);
        assertFalse(_guard(snap, emaBefore, bps, drift, net, out), "outside the band at 16H-1 must be refused");
        assertFalse(_guard(snap, emaAfter, bps, drift, net, out), "outside the band at 16H must be refused");
    }
}
