// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";

import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {LegStatus} from "../../src/libraries/PlanCheck.sol";
import {AttackBase} from "./AttackBase.t.sol";

/// @notice V2-10 scenario 6 and the named risk "flash-loaned depth". The registry has `MAX_STRATEGIES` slots; a newcomer
///         evicts the smallest only if its REAL depth (`min(virtual, wallet, allowance)`) is strictly larger.
///         (1) Phantom depth cannot evict: virtual balance with an empty wallet counts as zero.
///         (2) Flash depth CAN: an attacker funds a wallet, ships and registers inside one transaction, evicts the smallest
///         real maker, and returns the funds. The slot then has zero depth and anyone can `evict` it. No maker value
///         moves (wallet, Aqua balance and the shipped strategy are untouched); the cost is the maker's slot until it
///         registers again. Swaps in between are pool-only for that slot and never worse. Recorded in THREATS.md.
contract A06RegistryTest is AttackBase {
    function _full() internal {
        _attackInit();
        _initAnchor();
        _fill(6); // makers 0..5, depth 1,000 .. 6,000 each side
        assertEq(hookV2.strategiesOf(idV2).length, 6, "registry full");
    }

    function test_V210_phantomDepthCannotEvict() public {
        _full();
        address a = makers[7];
        // Virtual 1,000,000 each side, wallet nearly empty: real depth is the wallet.
        _fund(a, 10e18, 10e6);
        _ship(a, _p(), 1_000_000e18, 1_000_000e6);
        vm.prank(a);
        vm.expectPartialRevert(ConfluenceHook.DepthTooLow.selector);
        hookV2.register(keyV2, _p());
        assertTrue(_isRegistered(makers[0]), "the smallest real maker is still registered");
        assertFalse(_isRegistered(a), "the phantom maker is not");
    }

    function test_V210_flashLoanedDepthEvictsTheSmallestMakerAtNoCost() public {
        _full();
        address victim = makers[0];
        uint256 vW0 = mumb.balanceOf(victim);
        uint256 vU0 = IERC20(USDC).balanceOf(victim);
        bytes32 vHash = hookV2.strategiesOf(idV2)[0].strategyHash;
        (uint256 vv0,) = IAqua(AQUA).rawBalances(victim, ROUTER, vHash, address(mumb));

        // One transaction (modelled in one test body): borrow, ship, register, repay.
        address a = makers[7];
        _fund(a, 1_500e18, 1_500e6); // the borrowed funds
        _ship(a, _p(), 1_500e18, 1_500e6);
        _register(a, _p());
        assertFalse(_isRegistered(victim), "the smallest real maker was evicted");
        assertTrue(_isRegistered(a), "the flash depth holds the slot");
        uint256 aM = mumb.balanceOf(a);
        uint256 aU = IERC20(USDC).balanceOf(a);
        vm.startPrank(a);
        mumb.transfer(address(0xbeef), aM); // repay
        IERC20(USDC).transfer(address(0xbeef), aU);
        vm.stopPrank();

        // No maker value moved.
        assertEq(mumb.balanceOf(victim), vW0, "victim wallet MUMB");
        assertEq(IERC20(USDC).balanceOf(victim), vU0, "victim wallet USDC");
        (uint256 vv1,) = IAqua(AQUA).rawBalances(victim, ROUTER, vHash, address(mumb));
        assertEq(vv1, vv0, "victim's Aqua balance (the strategy is still shipped)");

        // Swaps in between: the attacker's slot is underfunded, the swap is never worse than pool-only.
        Run memory po = _poolOnly(keyV2, true, 1_000e6);
        Run memory r = _run(keyV2, true, 1_000e6, "");
        assertGe(r.got + 1, po.got, "never worse than pool-only");
        uint256 under;
        for (uint256 i; i < r.legs.length; i++) {
            if (r.legs[i].status == LegStatus.SKIP_UNDERFUNDED) under++;
        }
        assertEq(under, 1, "exactly the attacker's emptied slot is underfunded");

        // Anyone can free the slot; the victim registers again at no cost and is back.
        vm.prank(address(0xCAFE));
        hookV2.evict(keyV2, a);
        assertFalse(_isRegistered(a), "evicted");
        _register(victim, _p());
        assertTrue(_isRegistered(victim), "the victim is back");
        _assertClean();
    }
}
