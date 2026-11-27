// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import {ConfluenceSplitter} from "../../src/ConfluenceSplitter.sol";
import {LegStatus} from "../../src/libraries/PlanCheck.sol";
import {AttackBase} from "./AttackBase.t.sol";

/// @notice V2-10 scenario 7: a revert bomb. A router (or splitter) call that reverts or returns a huge payload. The hook's
///         `catch {}` binds no data, so the payload is never copied: a 500 kB revert costs the swap about what an empty one
///         does. A splitter that returns 100 kB is refused by the exact length check (`SKIP_PLAN`) and the swap is pool-only.
contract A07RevertBombTest is AttackBase {
    function _swapWithRouterRevert(uint256 bytesLen) internal returns (Run memory r) {
        bytes memory bomb = new bytes(bytesLen);
        vm.mockCallRevert(ROUTER, abi.encodeWithSelector(ISwapVM.swap.selector), bomb);
        r = _run(keyV2, true, 1_000e6, "");
        vm.clearMockedCalls();
    }

    function test_V210_routerRevertBombCostsAboutAnEmptyRevert() public {
        _attackInit();
        _initExact(keyV2);
        _threeMakers();
        Run memory po = _poolOnly(keyV2, true, 1_000e6);
        uint256 s = vm.snapshotState();
        Run memory empty = _swapWithRouterRevert(0);
        require(vm.revertToStateAndDelete(s), "revert failed");
        Run memory bomb = _swapWithRouterRevert(500_000);
        emit log_named_uint("gas, empty revert", empty.gasUsed);
        emit log_named_uint("gas, 500 kB revert", bomb.gasUsed);
        assertEq(bomb.got, po.got, "all legs failed: exactly pool-only");
        for (uint256 i; i < bomb.legs.length; i++) {
            assertTrue(
                bomb.legs[i].status == LegStatus.SKIP_REVERT || bomb.legs[i].amountIn == 0,
                "a leg is neither failed nor empty"
            );
        }
        assertLe(bomb.gasUsed, empty.gasUsed + 30_000, "the bomb's payload was paid for");
        _assertClean();
    }

    function test_V210_hugeSplitterReturnIsAPlanRefusal() public {
        _attackInit();
        _initExact(keyV2);
        M[] memory ms = _threeMakers();
        Run memory po = _poolOnly(keyV2, true, 1_000e6);
        bytes memory huge = new bytes(100_000);
        _expectPoolOnly(huge, false, true, 1_000e6, po, ms, "a 100 kB splitter return");
    }
}
