// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockMUMB} from "../../src/mocks/MockMUMB.sol";

/// @notice Shared fork setup. Every fork test extends this.
abstract contract ForkBase is Test {
    // Official mainnet contracts (docs/ARCHITECTURE.md section 1). Never modified or redeployed.
    address internal constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    address internal constant ROUTER = 0x111111338c5091E8440b67B168bAe16a668AC0De;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    uint256 internal constant PRIYA_MUMB = 1_000_000e18;
    uint256 internal constant TRADER_MUMB = 10_000e18;
    uint256 internal constant PRIYA_USDC = 1_000_000e6;
    uint256 internal constant TRADER_USDC = 100_000e6;

    address internal priya;
    address internal trader;
    address internal deployer;

    MockMUMB internal mumb;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("FORK_BLOCK"));

        priya = makeAddr("priya");
        trader = makeAddr("trader");
        deployer = makeAddr("deployer");

        vm.startPrank(deployer);
        mumb = new MockMUMB();
        mumb.mint(priya, PRIYA_MUMB);
        mumb.mint(trader, TRADER_MUMB);
        vm.stopPrank();

        deal(USDC, priya, PRIYA_USDC);
        deal(USDC, trader, TRADER_USDC);
    }

    /// @notice MUMB and USDC balances of `who`.
    function balances(address who) internal view returns (uint256 mumbBal, uint256 usdcBal) {
        mumbBal = mumb.balanceOf(who);
        usdcBal = IERC20(USDC).balanceOf(who);
    }

    /// @notice MUMB and USDC ordered by address, as v4 orders currency0 < currency1.
    function sortedPair() internal view returns (address currency0, address currency1) {
        (currency0, currency1) = address(mumb) < USDC ? (address(mumb), USDC) : (USDC, address(mumb));
    }
}
