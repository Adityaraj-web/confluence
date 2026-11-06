// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IExtruction, IStaticExtruction} from "@1inch/swap-vm/src/instructions/Extruction.sol";
import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";

/// @title PoolPriceBandExtruction
/// @notice Stateless Extruction target: refuses an Aqua fill priced more than `bandBps` away from a v4 pool's live
///         price. One `view` function serves both `quote()` (STATICCALL) and `swap()` (CALL).
/// @dev Args layout, packed, 88 bytes:
///      poolManager (20) | currency0 (20) | currency1 (20) | fee (3) | tickSpacing (3) | hooks (20) | bandBps (2)
contract PoolPriceBandExtruction is IExtruction, IStaticExtruction {
    /// @dev The swap's tokens are not the pool's two currencies.
    error PoolTokenMismatch();
    /// @dev The named pool's `sqrtPriceX96` is zero.
    error PoolNotInitialized();
    /// @dev A register is still zero: the step runs before the curve.
    error PoolPriceBandNotComputed();
    /// @dev The execution price is outside the band around the pool price.
    error PoolPriceBandExceeded(uint256 execX96, uint256 poolX96, uint16 bandBps);
    /// @dev `bandBps` is 0 or above 10,000.
    error InvalidBand();
    /// @dev The args are not exactly 88 bytes.
    error InvalidArgsLength(uint256 length);

    /// @notice Check a fill against the band. Called by a SwapVM router running a maker's program; anyone may call.
    function extruction(
        bool, /* isStaticContext */
        uint256, /* nextPC */
        SwapQuery calldata, /* query */
        SwapRegisters calldata, /* swap */
        bytes calldata, /* args */
        bytes calldata /* takerData */
    ) external view override(IExtruction, IStaticExtruction) returns (uint256, uint256, SwapRegisters memory) {
        revert();
    }

    /// @notice Encode the 88-byte args for a strategy. Anyone may call.
    function build(IPoolManager, /* poolManager */ PoolKey calldata, /* key */ uint16 /* bandBps */ )
        external
        pure
        returns (bytes memory)
    {
        revert();
    }

    /// @notice Decode the 88-byte args. Anyone may call.
    function parse(bytes calldata /* args */ )
        public
        pure
        returns (IPoolManager poolManager, PoolKey memory key, uint16 bandBps)
    {
        revert();
    }
}
