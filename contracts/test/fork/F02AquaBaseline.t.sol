// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {SwapVM} from "@1inch/swap-vm/src/SwapVM.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {BPS} from "@1inch/swap-vm/src/instructions/Fee.sol";

import {ForkBase} from "../base/ForkBase.t.sol";
import {StrategyLib} from "../base/StrategyLib.sol";
import {TakerHelper} from "../base/TakerHelper.sol";

/// @notice F02: ship Priya's strategy on the canonical router and fill it from a contract taker.
contract F02AquaBaselineTest is ForkBase, StrategyLib {
    uint256 internal constant SHIPPED_MUMB = 100_000e18;
    uint256 internal constant SHIPPED_USDC = 100_000e6;
    uint256 internal constant SWAP_USDC = 1_000e6;

    IAqua internal aqua = IAqua(AQUA);
    ISwapVM internal router = ISwapVM(ROUTER);

    ISwapVM.Order internal order;
    bytes32 internal strategyHash;
    TakerHelper internal helper;

    constructor() StrategyLib(AQUA) {}

    function setUp() public override {
        super.setUp();

        order = _buildOrder(priya, _buildProgram(FEE_0_30_PCT));

        address[] memory tokens = new address[](2);
        tokens[0] = address(mumb);
        tokens[1] = USDC;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SHIPPED_MUMB;
        amounts[1] = SHIPPED_USDC;

        vm.startPrank(priya);
        mumb.approve(AQUA, type(uint256).max);
        IERC20(USDC).approve(AQUA, type(uint256).max);
        strategyHash = aqua.ship(ROUTER, abi.encode(order), tokens, amounts);
        vm.stopPrank();

        helper = new TakerHelper(router);
    }

    /// @dev Exact output of fee (rounded up, on input) then XYC (rounded down) on the shipped balances.
    function _expectedOut(uint256 amountIn) internal pure returns (uint256) {
        uint256 net = amountIn - Math.ceilDiv(amountIn * FEE_0_30_PCT, BPS);
        return (net * SHIPPED_MUMB) / (SHIPPED_USDC + net);
    }

    function _virtualBalances() internal view returns (uint256 virtualMumb, uint256 virtualUsdc) {
        (virtualMumb, virtualUsdc) = aqua.safeBalances(priya, ROUTER, strategyHash, address(mumb), USDC);
    }

    function test_F02_shipCreatesVirtualBalances() public view {
        assertEq(strategyHash, router.hash(order), "strategy hash != router hash");
        assertEq(strategyHash, keccak256(abi.encode(order)), "strategy hash != keccak(abi.encode(order))");

        (uint256 virtualMumb, uint256 virtualUsdc) = _virtualBalances();
        assertEq(virtualMumb, SHIPPED_MUMB, "virtual MUMB");
        assertEq(virtualUsdc, SHIPPED_USDC, "virtual USDC");

        // Shipping moves no tokens.
        (uint256 walletMumb, uint256 walletUsdc) = balances(priya);
        assertEq(walletMumb, PRIYA_MUMB, "Priya wallet MUMB");
        assertEq(walletUsdc, PRIYA_USDC, "Priya wallet USDC");
    }

    function test_F02_takerContractSwap() public {
        uint256 expectedOut = _expectedOut(SWAP_USDC);
        deal(USDC, address(helper), SWAP_USDC);

        // The router and Aqua are live mainnet contracts, so measure them against their fork-block balances.
        uint256 routerUsdcBefore = IERC20(USDC).balanceOf(ROUTER);
        uint256 aquaUsdcBefore = IERC20(USDC).balanceOf(AQUA);

        (uint256 amountIn, uint256 amountOut,) =
            helper.swapExactIn(order, USDC, address(mumb), SWAP_USDC, expectedOut, trader);

        assertEq(amountIn, SWAP_USDC, "amountIn");
        assertEq(amountOut, expectedOut, "amountOut");
        assertGt(amountOut, 0, "amountOut is zero");

        // Priya's wallet: MUMB out, USDC in (Aqua's push forwards it to the maker).
        (uint256 walletMumb, uint256 walletUsdc) = balances(priya);
        assertEq(walletMumb, PRIYA_MUMB - amountOut, "Priya wallet MUMB");
        assertEq(walletUsdc, PRIYA_USDC + SWAP_USDC, "Priya wallet USDC");

        // Priya's virtual balances move the same way; the whole input, fee included, stays in her strategy.
        (uint256 virtualMumb, uint256 virtualUsdc) = _virtualBalances();
        assertEq(virtualMumb, SHIPPED_MUMB - amountOut, "virtual MUMB");
        assertEq(virtualUsdc, SHIPPED_USDC + SWAP_USDC, "virtual USDC");

        // The recipient got exactly the output and paid nothing.
        (uint256 traderMumb, uint256 traderUsdc) = balances(trader);
        assertEq(traderMumb, TRADER_MUMB + amountOut, "trader MUMB");
        assertEq(traderUsdc, TRADER_USDC, "trader USDC");

        // Nothing is left behind with the taker, the router or Aqua.
        _assertHoldsNothing(address(helper), "helper");
        assertEq(mumb.balanceOf(ROUTER), 0, "router MUMB");
        assertEq(mumb.balanceOf(AQUA), 0, "aqua MUMB");
        assertEq(IERC20(USDC).balanceOf(ROUTER), routerUsdcBefore, "router USDC changed");
        assertEq(IERC20(USDC).balanceOf(AQUA), aquaUsdcBefore, "aqua USDC changed");
        assertEq(IERC20(USDC).allowance(address(helper), ROUTER), 0, "helper allowance to router");
    }

    function test_F02_quoteMatchesSwap() public {
        deal(USDC, address(helper), SWAP_USDC);

        (uint256 quotedIn, uint256 quotedOut, bytes32 quotedHash) =
            helper.quoteExactIn(order, USDC, address(mumb), SWAP_USDC, 0);
        (uint256 swappedIn, uint256 swappedOut, bytes32 swappedHash) =
            helper.swapExactIn(order, USDC, address(mumb), SWAP_USDC, 0, trader);

        assertEq(quotedIn, swappedIn, "amountIn");
        assertEq(quotedOut, swappedOut, "amountOut");
        assertEq(quotedHash, swappedHash, "orderHash");
        assertEq(quotedHash, strategyHash, "orderHash != strategy hash");
    }

    function test_F02_noTxOriginRequirement() public {
        // An outside EOA with no tokens starts the transaction; the helper contract is the taker.
        address stranger = makeAddr("stranger");
        (uint256 strangerMumb, uint256 strangerUsdc) = balances(stranger);
        assertEq(strangerMumb, 0, "stranger MUMB");
        assertEq(strangerUsdc, 0, "stranger USDC");

        deal(USDC, address(helper), SWAP_USDC);
        uint256 expectedOut = _expectedOut(SWAP_USDC);

        vm.expectEmit(true, true, true, true, ROUTER);
        emit SwapVM.Swapped(strategyHash, priya, address(helper), USDC, address(mumb), SWAP_USDC, expectedOut);

        vm.prank(stranger, stranger);
        (, uint256 amountOut,) = helper.swapExactIn(order, USDC, address(mumb), SWAP_USDC, expectedOut, trader);

        assertEq(amountOut, expectedOut, "amountOut");
        _assertHoldsNothing(address(helper), "helper");
    }

    function _assertHoldsNothing(address who, string memory name) internal view {
        (uint256 mumbBal, uint256 usdcBal) = balances(who);
        assertEq(mumbBal, 0, string.concat(name, " MUMB"));
        assertEq(usdcBal, 0, string.concat(name, " USDC"));
    }
}
