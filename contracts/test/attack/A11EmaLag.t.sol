// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {AnchorLib} from "../../src/libraries/AnchorLib.sol";
import {LegStatus} from "../../src/libraries/PlanCheck.sol";
import {AttackBase} from "./AttackBase.t.sol";

/// @notice V2-10 scenario 11: EMA lag as a denial of service. After a real move the EMA trails the snapshot, so a maker
///         that re-centres its strategy on the new price is paused by its drift limit until the EMA catches up: the cost of
///         the defence. The pause lasts `60 * log2(gap / driftTicks)` seconds, whatever the block cadence (the EMA is an exact
///         time-weighted mean, D-31): about 52 s for the 550-tick move the fork pool can show and about 100 s for the 953
///         ticks (10%) the spec names (computed on `AnchorLib` itself; the fork pool's range is +/- 600 ticks).
contract A11EmaLagTest is AttackBase {
    using StateLibrary for IPoolManager;

    int256 internal constant U = 2 ** 16;

    /// @dev Seconds until the drift passes the 300-tick limit after a flat anchor jumps `gap` ticks, from `AnchorLib`.
    function _analyticSeconds(int24 gap) internal pure returns (uint256 t) {
        for (t = 1; t < 2_000; t++) {
            int256 d = int256(gap) * U - int256(AnchorLib.nextEmaX(0, gap, t, 60));
            if ((d < 0 ? -d : d) <= 300 * U) return t;
        }
    }

    function test_V210_analyticPauseFor953Ticks() public {
        uint256 t = _analyticSeconds(953);
        emit log_named_uint("seconds to un-pause after a 953-tick (10%) move", t);
        assertGe(t, 99, "about 100 s");
        assertLe(t, 101, "about 100 s");
    }

    /// @dev The market moves `550` ticks while no maker is registered; a maker then registers, re-centred on the new price.
    ///      Returns the move in ticks. No swap follows: `anchorOfX` is the anchor a swap would use at this moment.
    function _setupMove() internal returns (int24 gap) {
        _attackInit();
        _initExact(keyV2);
        (int24 fair,,) = hookV2.anchorOf(idV2);
        (, int24 now_,,) = manager.getSlot0(idV2);
        _swapLim(keyV2, true, 400_000e6, TickMath.getSqrtPriceAtTick(now_ - 550));
        (, int24 t1,,) = manager.getSlot0(idV2);
        gap = fair - t1;
        uint256 usdcAmt = 100_000e6;
        _joinM(keyV2, makers[1], _mumbAt(usdcAmt, t1), usdcAmt, _pf(3_000_000));
    }

    /// @dev Seconds, in steps of `cadence`, until the drift a swap would see is inside the 300-tick limit.
    function _driftSeconds(uint256 cadence) internal returns (uint256 elapsed) {
        while (elapsed < 600) {
            _nextBlock(cadence);
            elapsed += cadence;
            (int24 sn, int56 em,) = hookV2.anchorOfX(idV2);
            int256 d = int256(sn) * U - int256(em);
            if ((d < 0 ? -d : d) <= 300 * U) return elapsed;
        }
    }

    function _statusAfter(uint256 secs) internal returns (uint8) {
        _nextBlock(secs);
        Run memory r = _run(keyV2, false, 10e18, "");
        return r.legs.length > 0 ? r.legs[0].status : 99;
    }

    function test_V210_pauseAfterAMeasuredMove() public {
        int24 gap = _setupMove();
        uint256 s0 = vm.snapshotState();
        uint256 t1 = _driftSeconds(1);
        vm.revertToState(s0);
        uint256 t12 = _driftSeconds(12);
        uint256 analytic = _analyticSeconds(gap);
        emit log_named_uint("move (ticks)", uint256(int256(gap)));
        emit log_named_uint("analytic pause (s)", analytic);
        emit log_named_uint("measured, 1 s blocks", t1);
        emit log_named_uint("measured, 12 s blocks", t12);
        assertEq(t1, analytic, "1 s blocks: the pause is the analytic time to the second");
        assertGe(t12, analytic, "12 s blocks: not before the analytic pause");
        assertLe(t12, analytic + 12, "12 s blocks: within one block of it");
        // A real swap agrees at the boundary: one second early the maker is paused by drift, on time it fills.
        vm.revertToState(s0);
        assertEq(_statusAfter(t1 - 1), LegStatus.SKIP_DRIFT, "one second early: paused by drift");
        vm.revertToState(s0);
        assertEq(_statusAfter(t1), LegStatus.FILLED, "on time: the maker fills");
        _assertClean();
    }
}
