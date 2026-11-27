// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {AttackBase} from "./AttackBase.t.sol";

/// @notice Swap gas for pool-only, 1 and 3 makers, exact input (1,000 USDC in) and exact output (990 MUMB out), cold,
///         through `PoolSwapTest` on the V2-07/V2-09 fixture. Logs only (no ceilings; V2-11 budgets). Used to price any
///         change to the hook against V2-09's table (D-37).
contract A00GasTableTest is AttackBase {
    function _coldOut(uint256 amountOut) internal returns (uint256 used) {
        address[8] memory touched =
            [address(manager), address(hookV2), address(splitterOut), AQUA, ROUTER, USDC, address(mumb), _guard()];
        for (uint256 i; i < touched.length; i++) {
            vm.cool(touched[i]);
        }
        for (uint256 i; i < 6; i++) {
            vm.cool(makers[i]);
        }
        uint256 g = gasleft();
        _swap(keyV2, trader, true, int256(amountOut), "");
        used = g - gasleft();
    }

    function test_V210_gasTable() public {
        _initExact(keyV2);
        uint256 s = vm.snapshotState();
        uint256 i0 = _coldRun(keyV2, true, 1_000e6).gasUsed;
        uint256 o0 = _coldOut(990e18);
        vm.revertToState(s);
        _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
        uint256 s1 = vm.snapshotState();
        uint256 i1 = _coldRun(keyV2, true, 1_000e6).gasUsed;
        vm.revertToState(s1);
        uint256 o1 = _coldOut(990e18);
        vm.revertToState(s);
        _threeMakers();
        uint256 s3 = vm.snapshotState();
        uint256 i3 = _coldRun(keyV2, true, 1_000e6).gasUsed;
        vm.revertToState(s3);
        uint256 o3 = _coldOut(990e18);
        console2.log("GAS exact-in  pool-only", i0);
        console2.log("GAS exact-in  1 maker  ", i1);
        console2.log("GAS exact-in  3 makers ", i3);
        console2.log("GAS exact-out pool-only", o0);
        console2.log("GAS exact-out 1 maker  ", o1);
        console2.log("GAS exact-out 3 makers ", o3);
    }
}
