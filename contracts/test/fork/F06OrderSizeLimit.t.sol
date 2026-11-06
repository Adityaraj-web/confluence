// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {ConfluenceBase} from "../base/ConfluenceBase.t.sol";

/// @notice F06 follow-up (D-20): `registerOrder` refuses an `order.data` longer than `MAX_ORDER_DATA_BYTES`, because
/// the hook copies the stored order out of storage on every hinted swap, before its gas check.
contract F06OrderSizeLimitTest is ConfluenceBase {
    uint256 internal constant SWAP_USDC = 1_000e6;

    /// @dev `data` of `priyaOrder` padded with zeros (or cut) to `length` bytes. The router will not accept it as a
    /// strategy (it was never shipped), which is the point: the hook must still never fail the swap.
    function _orderWithDataLength(uint256 length) internal view returns (ISwapVM.Order memory order) {
        order = priyaOrder;
        order.data = new bytes(length);
        for (uint256 i; i < length && i < priyaOrder.data.length; i++) {
            order.data[i] = priyaOrder.data[i];
        }
    }

    // ---------------------------------------------------------------- acceptance

    /// @dev One byte over the limit is refused with the length and the limit, and the registered order is untouched.
    function test_F06_oversizedOrderRefused() public {
        uint256 max = hook.MAX_ORDER_DATA_BYTES();
        ISwapVM.Order memory big = _orderWithDataLength(max + 1);

        vm.prank(priya);
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.OrderDataTooLarge.selector, max + 1, max));
        hook.registerOrder(key, big);

        ISwapVM.Order memory stored = hook.orderOf(poolId);
        assertEq(stored.maker, priya, "original order still registered");
        assertEq(keccak256(stored.data), keccak256(priyaOrder.data), "original data untouched");
    }

    /// @dev Exactly `MAX_ORDER_DATA_BYTES` registers, emits `OrderRegistered`, and is stored in full.
    function test_F06_orderAtLimitRegisters() public {
        uint256 max = hook.MAX_ORDER_DATA_BYTES();
        ISwapVM.Order memory atLimit = _orderWithDataLength(max);

        vm.expectEmit(true, true, false, true, address(hook));
        emit ConfluenceHook.OrderRegistered(poolId, priya, keccak256(abi.encode(atLimit)));
        vm.prank(priya);
        hook.registerOrder(key, atLimit);

        ISwapVM.Order memory stored = hook.orderOf(poolId);
        assertEq(stored.data.length, max, "stored in full");
        assertEq(keccak256(stored.data), keccak256(atLimit.data), "stored data equal");
    }

    /// @dev Priya's real order (118 bytes, measured) is far under the limit: the limit is about 4x its length.
    function test_F06_priyaOrderRegistersUnderLimit() public {
        uint256 len = priyaOrder.data.length;
        emit log_named_uint("priyaOrder.data.length", len);
        assertEq(len, 118, "measured length of Priya's order.data");
        assertLe(4 * len, hook.MAX_ORDER_DATA_BYTES(), "limit is at least 4x Priya's order");

        vm.prank(priya);
        hook.registerOrder(key, priyaOrder);
        assertEq(keccak256(hook.orderOf(poolId).data), keccak256(priyaOrder.data), "same order registered");
    }

    /// @dev The claim behind the limit: with the largest order the hook accepts, a hinted swap never reverts at a
    /// transaction gas limit where the pool-only swap passes. Same 52 limits as `test_F06_neverCostsTheSwapAtAnyGasLimit`.
    function test_F06_orderAtLimitNeverCostsTheSwap() public {
        ISwapVM.Order memory atLimit = _orderWithDataLength(hook.MAX_ORDER_DATA_BYTES());
        vm.prank(priya);
        hook.registerOrder(key, atLimit);

        // The sweep only means something if the hook gets as far as the router with the big order: at a roomy
        // limit it must skip because the router refused it, not because of `InsufficientGas`.
        uint256 snapRoomy = vm.snapshotState();
        vm.recordLogs();
        assertTrue(_tryAtLimit(1_500_000, _hint(SWAP_USDC)), "hinted swap passes at a roomy limit");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.revertToState(snapRoomy);
        uint256 skips;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == ConfluenceHook.AquaSkipped.selector) {
                skips++;
                bytes memory reason = abi.decode(logs[i].data, (bytes));
                assertTrue(
                    bytes4(reason) != ConfluenceHook.InsufficientGas.selector, "reached the router, not a gas skip"
                );
            }
        }
        assertEq(skips, 1, "exactly one AquaSkipped: the router refused the at-limit order");

        uint256[] memory limits = _gasLimits();
        uint256 checked;
        for (uint256 i; i < limits.length; i++) {
            uint256 snap = vm.snapshotState();
            bool poolOk = _tryAtLimit(limits[i], "");
            vm.revertToState(snap);
            if (!poolOk) continue;
            checked++;

            snap = vm.snapshotState();
            bool hintOk = _tryAtLimit(limits[i], _hint(SWAP_USDC));
            vm.revertToState(snap);
            assertTrue(hintOk, string.concat("hinted swap reverted at gas limit ", vm.toString(limits[i])));
        }
        assertGe(checked, 50, "precondition: the pool alone passes at (nearly) every limit");
    }

    // ---------------------------------------------------------------- helpers (as in F06Safety.t.sol)

    /// @dev One 1,000 USDC exact-input swap with `hookData` under a transaction gas limit of `limit`; false if it
    /// reverted. Leaves its state changes in place on success.
    function _tryAtLimit(uint256 limit, bytes memory hookData) internal returns (bool ok) {
        vm.startPrank(trader);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        mumb.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: usdcForMumb(),
            amountSpecified: -int256(SWAP_USDC),
            sqrtPriceLimitX96: usdcForMumb() ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.prank(trader);
        try swapRouter.swap{gas: limit}(key, params, settings, hookData) returns (BalanceDelta) {
            ok = true;
        } catch {}
    }

    /// @dev The transaction gas limits of the sweep: 285,000 to 500,000 in steps of 5,000, then eight larger ones.
    function _gasLimits() internal pure returns (uint256[] memory limits) {
        uint256 n = (500_000 - 285_000) / 5_000 + 1;
        limits = new uint256[](n + 8);
        for (uint256 i; i < n; i++) {
            limits[i] = 285_000 + i * 5_000;
        }
        uint256[8] memory high =
            [uint256(550_000), 600_000, 700_000, 800_000, 1_000_000, 1_500_000, 2_000_000, 3_000_000];
        for (uint256 i; i < 8; i++) {
            limits[n + i] = high[i];
        }
    }
}
