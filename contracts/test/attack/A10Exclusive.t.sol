// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import {TakerNotHook} from "../../src/BandGuardV2.sol";
import {TakerHelper} from "../base/TakerHelper.sol";
import {AttackBase} from "./AttackBase.t.sol";

/// @notice V2-10 scenario 10: skipping the hook. A contract (or anyone) calls the canonical router directly to fill or
///         quote a registered, exclusive strategy: the guard refuses every taker but the hook, on swap and on quote,
///         and nothing moves. PnL 0 for the attacker and the maker.
contract A10ExclusiveTest is AttackBase {
    function test_V210_directRouterFillAndQuoteAreRefused() public {
        M memory m = _oneMakerPool(100_000e18, 100_000e6);
        TakerHelper helper = new TakerHelper(ISwapVM(ROUTER));
        deal(USDC, address(helper), 1_000e6);
        ISwapVM.Order memory order = _order(keyV2, m);
        int256 m0 = _value(makers[0], address(mumb));
        int256 h0 = _value(address(helper), address(mumb));
        bytes memory refused = abi.encodeWithSelector(TakerNotHook.selector, address(helper));
        vm.expectRevert(refused);
        helper.swapExactIn(order, USDC, address(mumb), 1_000e6, 0, attacker);
        vm.expectRevert(refused);
        helper.quoteExactIn(order, USDC, address(mumb), 1_000e6, 0);
        assertEq(_value(makers[0], address(mumb)), m0, "maker PnL 0");
        assertEq(_value(address(helper), address(mumb)), h0, "attacker PnL 0");
        _assertClean();
        // The same strategy still fills through the hook.
        Run memory r = _run(keyV2, true, 1_000e6, "");
        assertEq(uint256(r.legs[0].status), 0, "through the hook it fills");
    }
}
