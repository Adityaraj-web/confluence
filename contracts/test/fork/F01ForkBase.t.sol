// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {ForkBase} from "../base/ForkBase.t.sol";
import {MockMUMB} from "../../src/mocks/MockMUMB.sol";

/// @dev Minimal view of the canonical router; we only read it, never import or deploy its code.
interface IAquaBound {
    function AQUA() external view returns (address);
}

contract F01ForkBaseTest is ForkBase {
    function test_F01_officialContractsExist() public view {
        assertGt(AQUA.code.length, 0, "Aqua has no code");
        assertGt(ROUTER.code.length, 0, "router has no code");
        assertGt(POOL_MANAGER.code.length, 0, "PoolManager has no code");
    }

    function test_F01_routerBoundToAqua() public view {
        assertEq(IAquaBound(ROUTER).AQUA(), AQUA, "router AQUA() mismatch");

        (, string memory name, string memory version,, address verifyingContract,,) = IERC5267(ROUTER).eip712Domain();
        assertEq(version, "1.0.2", "router EIP-712 version");
        assertEq(verifyingContract, ROUTER, "verifyingContract");
        // docs say "1inch SwapVM v1.0"; assert it so a mismatch is loud
        assertEq(name, "1inch SwapVM v1.0", "router EIP-712 name");
    }

    function test_F01_actorsFunded() public view {
        (uint256 mumb, uint256 usdc) = balances(priya);
        assertEq(mumb, 1_000_000e18, "priya MUMB");
        assertEq(usdc, 1_000_000e6, "priya USDC");

        (mumb, usdc) = balances(trader);
        assertEq(mumb, 10_000e18, "trader MUMB");
        assertEq(usdc, 100_000e6, "trader USDC");

        (mumb, usdc) = balances(deployer);
        assertEq(mumb, 0, "deployer MUMB");
        assertEq(usdc, 0, "deployer USDC");
    }

    function test_F01_sortedPair() public view {
        (address c0, address c1) = sortedPair();
        assertLt(uint160(c0), uint160(c1), "not sorted");
        assertTrue(
            (c0 == address(mumb) && c1 == USDC) || (c0 == USDC && c1 == address(mumb)),
            "pair is not MUMB/USDC"
        );
        (address d0, address d1) = sortedPair();
        assertEq(c0, d0);
        assertEq(c1, d1);
    }

    function test_F01_mintOnlyDeployer() public {
        vm.prank(trader);
        vm.expectRevert(MockMUMB.NotDeployer.selector);
        mumb.mint(trader, 1);
    }
}
