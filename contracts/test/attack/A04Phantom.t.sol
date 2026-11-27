// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";

import {StrategyTemplate} from "../../src/libraries/StrategyTemplate.sol";
import {LegStatus} from "../../src/libraries/PlanCheck.sol";
import {AttackBase} from "./AttackBase.t.sol";

/// @notice V2-10 scenario 4: a phantom depth. A maker's Aqua virtual balance can be larger than what it holds (the wallet
///         is its own and tokens move only on a fill), and wallet and allowance can change after it registered. The hook
///         prices a maker at `min(virtual, wallet, allowance)` BEFORE allocating, so a phantom balance never gets a share
///         the maker cannot pay. Every case: the swap does not revert, the victim gets exactly what it gets from the pool
///         alone when the maker is dropped, and the books are exact.
contract A04PhantomTest is AttackBase {
    /// @dev Pool-only result for the swap and the hooked result with the damaged maker; both from one snapshot.
    function _compare(uint256 amount) internal returns (Run memory po, Run memory r) {
        po = _poolOnly(keyV2, true, amount);
        r = _run(keyV2, true, amount, "");
    }

    function _skipped(Run memory r) internal pure returns (uint8 st) {
        st = r.legs[0].status;
    }

    function test_V210_walletDrainedAfterRegistration() public {
        _oneMakerPool(100_000e18, 100_000e6);
        uint256 all = mumb.balanceOf(makers[0]);
        vm.prank(makers[0]);
        mumb.transfer(address(0xdead), all); // the maker empties its wallet
        (Run memory po, Run memory r) = _compare(1_000e6);
        emit log_named_uint("status (4 = SKIP_UNDERFUNDED)", _skipped(r));
        assertEq(_skipped(r), LegStatus.SKIP_UNDERFUNDED, "a drained maker is underfunded");
        assertEq(r.got, po.got, "the victim gets exactly the pool-only output");
        assertEq(r.legs[0].amountIn + r.legs[0].amountOut, 0, "nothing moved");
        _assertClean();
    }

    function test_V210_allowanceRevokedAfterRegistration() public {
        _oneMakerPool(100_000e18, 100_000e6);
        vm.prank(makers[0]);
        mumb.approve(AQUA, 0);
        (Run memory po, Run memory r) = _compare(1_000e6);
        assertEq(_skipped(r), LegStatus.SKIP_UNDERFUNDED, "a maker that revoked its allowance is underfunded");
        assertEq(r.got, po.got, "exactly pool-only");
        _assertClean();
    }

    function test_V210_dockedAfterRegistration() public {
        M memory m = _oneMakerPool(100_000e18, 100_000e6);
        vm.prank(makers[0]);
        IAqua(AQUA).dock(ROUTER, m.hash, _tokens());
        (Run memory po, Run memory r) = _compare(1_000e6);
        emit log_named_uint("status after dock", _skipped(r));
        assertTrue(_skipped(r) != LegStatus.FILLED, "a docked strategy filled");
        assertEq(r.got, po.got, "exactly pool-only");
        _assertClean();
    }

    /// @dev Virtual balance 100x the wallet: the real depth is the wallet, the leg is sized on it, the maker pays what it
    ///      has and no more.
    function test_V210_virtualBalanceLargerThanTheWallet() public {
        _attackInit();
        _initExact(keyV2);
        M memory m = _joinM(keyV2, makers[0], 1_000e18, 1_000e6, _pf(3_000_000));
        // Replace it with the same program under a new salt (a strategy cannot be shipped twice) and a virtual balance
        // 100x the wallet.
        vm.prank(makers[0]);
        IAqua(AQUA).dock(ROUTER, m.hash, _tokens());
        vm.prank(makers[0]);
        hookV2.unregister(keyV2);
        StrategyTemplate.Params memory p2 = m.p;
        p2.salt = 1;
        _ship(makers[0], p2, 100_000e18, 100_000e6);
        _register(makers[0], p2);
        uint256 wallet0 = mumb.balanceOf(makers[0]);
        (Run memory po, Run memory r) = _compare(1_000e6);
        emit log_named_uint("maker sold (MUMB raw)", r.legs[0].amountOut);
        assertEq(_skipped(r), LegStatus.FILLED, "non-vacuous: the real depth is still usable");
        assertLe(r.legs[0].amountOut, wallet0, "the leg is never more than the maker's wallet");
        assertGe(r.got + 1, po.got, "never worse than pool-only");
        assertEq(mumb.balanceOf(makers[0]), wallet0 - r.legs[0].amountOut, "the maker paid exactly the leg");
        _assertClean();
    }
}
