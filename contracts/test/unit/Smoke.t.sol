// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IExtruction} from "@1inch/swap-vm/src/instructions/Extruction.sol";
import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";

/// F00: proves v4-core and swap-vm v1.0.2 types compile together under one remapping set.
contract SmokeTest is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function test_F00_smoke() public pure {
        IPoolManager pm = IPoolManager(POOL_MANAGER);
        assertEq(address(pm), POOL_MANAGER);
        // selector of the swap-vm Extruction entrypoint is reachable through the imported interface
        assertTrue(IExtruction.extruction.selector != bytes4(0));
        SwapQuery memory q;
        SwapRegisters memory r;
        assertEq(q.maker, address(0));
        assertEq(r.balanceIn, 0);
    }
}
