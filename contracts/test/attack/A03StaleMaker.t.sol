// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {LegStatus} from "../../src/libraries/PlanCheck.sol";
import {AttackBase} from "./AttackBase.t.sol";

/// @notice V2-10 scenario 3: a stale maker. The market moves while the maker's strategy keeps its old curve. The market
///         move is made while the maker is unregistered (a deep registered maker absorbs a trader and keeps the pool at its
///         own price, so it cannot be made stale by trading through the hook); the maker then registers again, stale.
///         Inside the band it fills (its loss against the new market is bounded by the band); outside it, it is skipped and
///         nothing of it moves.
contract A03StaleMakerTest is AttackBase {
    using StateLibrary for IPoolManager;

    function _moveMarket(int24 shift) internal returns (int24 tick) {
        _unregisterAll(keyV2);
        (, int24 now_,,) = manager.getSlot0(idV2);
        int24 target = now_ - shift;
        bool zfo = target < now_;
        _swapLim(keyV2, zfo, zfo ? 400_000e6 : 400_000e18, TickMath.getSqrtPriceAtTick(target));
        (, tick,,) = manager.getSlot0(idV2);
    }

    /// @dev `who`'s holdings in raw USDC at the market price of `tick`.
    function _valueAt(address who, int24 tick) internal view returns (int256) {
        return int256(IERC20U(USDC).balanceOf(who)) + int256(mumb.balanceOf(who) * 1e6 / _mumbAt(1e6, tick));
    }

    function test_V210_staleMakerOutsideTheBandIsSkipped() public {
        M memory m = _oneMakerPool(100_000e18, 100_000e6);
        uint256 w0 = mumb.balanceOf(makers[0]);
        uint256 u0 = IERC20U(USDC).balanceOf(makers[0]);
        int24 t = _moveMarket(450); // 4.5% away: inside the pool's range, far outside the 2% band
        _nextBlock(12);
        vm.prank(makers[0]);
        hookV2.register(keyV2, m.p);
        // Right after: the EMA is still near the old price, so the drift limit is what stops the maker.
        Run memory r1 = _run(keyV2, false, 200e18, ""); // MUMB in: back toward the range centre
        emit log_named_uint("status right after the move (3 = SKIP_DRIFT)", r1.legs[0].status);
        assertTrue(r1.legs[0].status != LegStatus.FILLED, "a stale maker filled right after a 4.5% move");
        // After 16 half-lives the EMA has caught up: only the band is left.
        _nextBlock(1_000);
        Run memory r2 = _run(keyV2, false, 200e18, "");
        emit log_named_uint("status after the EMA caught up (2 = SKIP_BAND)", r2.legs[0].status);
        assertEq(r2.legs[0].status, LegStatus.SKIP_BAND, "the band stops a stale maker");
        assertEq(mumb.balanceOf(makers[0]), w0, "the maker's MUMB did not move");
        assertEq(IERC20U(USDC).balanceOf(makers[0]), u0, "the maker's USDC did not move");
        assertEq(r2.legs[0].amountIn + r2.legs[0].amountOut, 0, "no fill");
        _assertClean();
        t;
    }

    function test_V210_staleMakerInsideTheBandLosesAtMostTheBand() public {
        M memory m = _oneMakerPool(100_000e18, 100_000e6);
        int24 t = _moveMarket(120); // 1.2% away: inside the 2% band
        _nextBlock(1_000); // the EMA catches up: the drift limit is not the issue
        vm.prank(makers[0]);
        hookV2.register(keyV2, m.p);
        int256 v0 = _valueAt(makers[0], t);
        uint256 snap0 = vm.snapshotState();
        Run memory big = _run(keyV2, true, 2_000e6, "");
        emit log_named_uint("2,000 USDC probe: maker sold (MUMB raw)", big.legs[0].amountOut);
        // A big fill moves the maker's own price past the new market (its price impact), so it can end ahead; only a SMALL
        // fill shows the stale-price loss. The two numbers are logged; the loss bound is asserted on the small fill.
        emit log_named_int("2,000 USDC probe: maker PnL vs the new market", _valueAt(makers[0], t) - v0);
        require(vm.revertToStateAndDelete(snap0), "revert failed");
        v0 = _valueAt(makers[0], t);
        Run memory r = _run(keyV2, true, 100e6, "");
        int256 v1 = _valueAt(makers[0], t);
        emit log_named_uint("status", r.legs[0].status);
        emit log_named_uint("maker sold (MUMB raw)", r.legs[0].amountOut);
        emit log_named_int("maker PnL vs the NEW market price (raw USDC)", v1 - v0);
        assertEq(r.legs[0].status, LegStatus.FILLED, "non-vacuous: inside the band the stale maker fills");
        // It sold at its stale curve while the market was 1.2% higher: a loss, bounded by the band (2%) of what it sold.
        assertLt(v1 - v0, 0, "the stale fill is a loss at the new market price: the exposure is real");
        assertGe(v1 - v0, -int256(r.legs[0].amountIn * 200 / 10_000), "the loss exceeds the band bound");
        _assertClean();
    }
}

interface IERC20U {
    function balanceOf(address) external view returns (uint256);
}
