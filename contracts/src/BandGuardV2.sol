// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IExtruction, IStaticExtruction} from "@1inch/swap-vm/src/instructions/Extruction.sol";
import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";

// STUB (red first): V2-04 step 1. Interface, errors and types are final; the checks are not written yet.

/// @dev The args are not exactly 91 bytes.
error InvalidArgsLength(uint256 length);
/// @dev `bandBps` is 0 or above 10,000.
error InvalidBand();
/// @dev `driftTicks` is above `MAX_DRIFT_TICKS`.
error InvalidDrift();
/// @dev A flag bit other than bit 0 is set.
error InvalidFlags(uint8 flags);
/// @dev The swap's tokens are not the pool's two currencies.
error PoolTokenMismatch();
/// @dev The strategy is exclusive and the taker is not the pool's hook.
error TakerNotHook(address taker);
/// @dev The snapshot and the EMA are more than `driftTicks` apart.
error AnchorDrift(int24 snapTick, int56 emaTickX, uint16 driftTicks);
/// @dev A register is still zero: the step runs before the curve.
error BandNotComputed();
/// @dev The execution price is outside the band around the snapshot price.
error BandExceeded(uint256 execX, uint256 refX, uint16 bandBps);

/// @notice The hook's anchor, unrounded. `ConfluenceHook.anchorOfX`.
interface IConfluenceAnchor {
    function anchorOfX(PoolId poolId) external view returns (int24 snapTick, int56 emaTickX, bool fresh);
}

library BandGuardArgs {
    uint256 internal constant ARGS_LENGTH = 91;
    uint16 internal constant MAX_BAND_BPS = 10_000;
    uint16 internal constant MAX_DRIFT_TICKS = 10_000;
    uint8 internal constant FLAG_EXCLUSIVE = 1;

    struct Args {
        IPoolManager poolManager;
        PoolKey key;
        uint16 bandBps;
        uint16 driftTicks;
        uint8 flags;
    }

    function build(IPoolManager, PoolKey memory, uint16, uint16, uint8) internal pure returns (bytes memory out) {}

    function parse(bytes calldata) internal pure returns (Args memory a) {}
}

contract BandGuardV2 is IExtruction, IStaticExtruction {
    function extruction(bool, uint256 nextPC, SwapQuery calldata, SwapRegisters calldata swap, bytes calldata, bytes calldata)
        external
        view
        override(IExtruction, IStaticExtruction)
        returns (uint256, uint256, SwapRegisters memory)
    {
        return (nextPC, 0, swap);
    }

    function build(IPoolManager poolManager, PoolKey calldata key, uint16 bandBps, uint16 driftTicks, uint8 flags)
        external
        pure
        returns (bytes memory)
    {
        return BandGuardArgs.build(poolManager, key, bandBps, driftTicks, flags);
    }

    function parse(bytes calldata args)
        external
        pure
        returns (IPoolManager poolManager, PoolKey memory key, uint16 bandBps, uint16 driftTicks, uint8 flags)
    {
        BandGuardArgs.Args memory a = BandGuardArgs.parse(args);
        return (a.poolManager, a.key, a.bandBps, a.driftTicks, a.flags);
    }
}
