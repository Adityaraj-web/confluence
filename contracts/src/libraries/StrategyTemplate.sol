// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

/// @title StrategyTemplate
/// @notice STUB (red phase): the real body arrives in the next commit.
library StrategyTemplate {
    struct Params {
        uint32 feeE9;
        uint16 bandBps;
        uint16 driftTicks;
        bool exclusive;
        uint64 salt;
    }

    uint8 internal constant OP_SALT = 0;
    uint8 internal constant OP_FLAT_FEE = 0;
    uint8 internal constant OP_XYC_SWAP = 0;
    uint8 internal constant OP_EXTRUCTION = 0;

    error InvalidMakerFee(uint32 feeE9);

    function program(Params memory, IPoolManager, PoolKey memory, address) internal pure returns (bytes memory) {
        return "";
    }

    function order(address, bytes memory) internal pure returns (ISwapVM.Order memory o) {
        return o;
    }

    function strategyHash(ISwapVM.Order memory) internal pure returns (bytes32) {
        return bytes32(0);
    }

    function depthValue(uint256, uint256, int24) internal pure returns (uint256) {
        return 0;
    }
}
