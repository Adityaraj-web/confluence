// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {LegStatus} from "../../src/libraries/PlanCheck.sol";
import {AttackBase} from "./AttackBase.t.sol";

/// @notice V2-10 scenario 2: cross-block manipulation. The attacker moves the pool in block N and leaves it; in block N+1
///         the first swap records the manipulated price as the snapshot. The EMA moves only part-way toward it (12.9% of
///         the gap in a 12 s block, `EMA_HALF_LIFE` 60), so a maker whose `driftTicks` is 300 pauses once the post-update
///         gap `|snap - ema|` passes 300: a pre-update gap of about 344 ticks. The test measures, for several pushes, the
///         gap, the drift, the maker's status and the maker's and attacker's PnL.
contract A02CrossBlockTest is AttackBase {
    using StateLibrary for IPoolManager;

    int256 internal constant U = 2 ** 16;

    /// @dev Pushes the pool's tick to `target` with a limited swap from the trader (a USDC-in swap lowers the tick).
    function _pushTo(int24 target) internal returns (int24 got) {
        (, int24 now_,,) = manager.getSlot0(idV2);
        bool zfo = target < now_;
        _swapLim(keyV2, zfo, zfo ? 400_000e6 : 400_000e18, TickMath.getSqrtPriceAtTick(target));
        (, got,,) = manager.getSlot0(idV2);
    }

    struct Row {
        int24 gap; // pool tick distance from the fair snapshot after the push (block N)
        uint256 driftX; // |snap - ema| in X units after block N+1's update
        uint8 status;
        uint256 makerSold; // the maker's output in the probe swap
        int256 makerPnl;
        int256 attackerPnl; // the trader as attacker: push in block N, unwind in block N+1
    }

    function _row(int24 shift) internal returns (Row memory r) {
        M memory m = _oneMakerPool(100_000e18, 100_000e6);
        (int24 fair,,) = hookV2.anchorOf(idV2);
        int256 m0 = _value(makers[0], address(mumb));
        int256 a0 = _value(trader, address(mumb));
        uint256 usdc0 = IERC20(USDC).balanceOf(trader);
        int24 t = _pushTo(fair - shift);
        uint256 held = mumb.balanceOf(trader);
        r.gap = fair - t;
        _nextBlock(12);
        // The first swap of block N+1: the snapshot is the pushed price. A 100 USDC probe in the direction that BUYS from
        // the maker (USDC in).
        Run memory run = _run(keyV2, true, 100e6, "");
        (int24 snap, int56 ema,) = hookV2.anchorOfX(idV2);
        int256 d = int256(snap) * U - int256(ema);
        r.driftX = uint256(d < 0 ? -d : d);
        r.status = run.legs[0].status;
        r.makerSold = run.legs[0].amountOut;
        // Unwind: the attacker sells back the MUMB the push gave it (all of its MUMB above the starting 5,000,000), in
        // block N+1, through the hook.
        uint256 gained = IERC20(USDC).balanceOf(trader) < usdc0 ? held - 5_000_000e18 : 0;
        if (gained > 0) _swapLim(keyV2, false, gained, TickMath.MAX_SQRT_PRICE - 1);
        r.makerPnl = _value(makers[0], address(mumb)) - m0;
        r.attackerPnl = _value(trader, address(mumb)) - a0;
        // The pause is the drift limit exactly: a maker that is FILLED had a drift inside its 300 ticks; a drift outside
        // it is never filled.
        if (r.status == LegStatus.FILLED) assertLe(r.driftX, 300 * uint256(U), "filled past the drift limit");
        if (r.driftX > 300 * uint256(U)) {
            assertTrue(r.status != LegStatus.FILLED, "a maker past its drift limit filled");
        }
        _assertClean();
    }

    function test_V210_crossBlockPause() public {
        int24[7] memory shifts = [int24(50), 150, 250, 330, 360, 400, 600];
        uint256 firstPaused = type(uint256).max;
        for (uint256 i; i < shifts.length; i++) {
            uint256 s = vm.snapshotState();
            Row memory r = _row(shifts[i]);
            emit log_named_string(
                string.concat(
                    "push ", vm.toString(int256(shifts[i])), " ticks (achieved ", vm.toString(int256(r.gap)), ")"
                ),
                string.concat(
                    "drift ticks x1000 ",
                    vm.toString(r.driftX * 1000 / uint256(U)),
                    ", maker status ",
                    vm.toString(r.status),
                    ", maker sold ",
                    vm.toString(r.makerSold),
                    ", maker PnL ",
                    vm.toString(r.makerPnl),
                    ", attacker PnL ",
                    vm.toString(r.attackerPnl)
                )
            );
            // The EMA moves 1 - 2^(-12/60) = 12.94% of the gap toward the snapshot in a 12 s block: the drift left is 0.8706 of
            // the gap (within half a percent), so a 300-tick limit pauses a maker from a gap of about 344 ticks.
            assertApproxEqRel(
                r.driftX * 1000 / uint256(U), uint256(int256(r.gap)) * 870_6 / 10, 0.005e18, "drift = 0.8706 gap"
            );
            // The cycle costs the attacker and pays the maker: its fills were inside the band, at a premium to fair.
            assertLt(r.attackerPnl, 0, "the cross-block push paid the attacker");
            assertGe(r.makerPnl, 0, "the cross-block push cost the maker");
            if (r.status != LegStatus.FILLED && firstPaused == type(uint256).max) firstPaused = uint256(int256(r.gap));
            require(vm.revertToStateAndDelete(s), "revert failed");
        }
        // Some push pauses the maker, and the smallest pausing gap is near the analytic 344 ticks (drift 300 / 0.871) or
        // the band edge (about 198 ticks), whichever binds first.
        assertLt(firstPaused, type(uint256).max, "no push paused the maker: the test is vacuous");
        emit log_named_uint("smallest pre-update gap at which the maker did not fill", firstPaused);
    }
}
