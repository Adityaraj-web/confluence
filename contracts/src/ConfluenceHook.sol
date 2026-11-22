// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {AnchorLib} from "./libraries/AnchorLib.sol";

/// @title ConfluenceHook (v2)
/// @notice A Uniswap v4 hook that keeps a block-start price anchor per pool: the `slot0` tick at the block's first
/// swap, and a time-weighted EMA of those snapshots (ARCHITECTURE-v2 section 4). Immutable, ownerless, no admin.
/// V2-03: every swap is pool-only (zero delta, no LP-fee override); maker logic arrives in V2-05 to V2-07.
/// @dev Implements `IHooks` directly (D-17). Callbacks other than `beforeSwap` revert; the PoolManager never calls
/// them because the address flags are off. This hook never calls `PoolManager.swap` itself: the PoolManager skips the
/// hook for a swap whose caller is the hook (`Hooks.sol:252`), which would bypass the anchor update (D-31).
contract ConfluenceHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev `beforeSwap` was called by an address other than the PoolManager.
    error NotPoolManager();
    /// @dev A hook callback this contract does not implement.
    error HookNotImplemented();
    /// @dev The pool has no price (`slot0.sqrtPriceX96 == 0`). Tick 0 is a valid price, so the anchor must not read as
    /// zeros for a pool that does not exist: a wrong pool key would otherwise pass a band check.
    error PoolNotInitialized();

    /// @notice The anchor of `poolId` was recorded: the first swap of a new block. `emaTickX` is tick x 2^16.
    event AnchorUpdated(PoolId indexed poolId, int24 snapTick, int56 emaTickX, uint40 timestamp);

    /// @notice The Uniswap v4 PoolManager this hook serves.
    IPoolManager public immutable poolManager;
    /// @notice Half-life of the EMA, in seconds (V2-11 may change it with a DECISIONS entry).
    uint256 public constant EMA_HALF_LIFE = 60;

    /// @dev One packed slot per pool (slot 0 of this contract is the mapping's base).
    mapping(PoolId => AnchorLib.Anchor) internal _anchors;

    /// @param _poolManager The v4 PoolManager.
    /// @dev Reverts unless the deployed address carries exactly the flags in `getHookPermissions`.
    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice The hook's permissions: `beforeSwap` and `beforeSwapReturnDelta` only. Anyone may call.
    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true;
    }

    /// @notice The pool's anchor now: the block-start snapshot tick, the EMA rounded to the nearest tick, and whether
    /// it was stored this block. Anyone may call.
    /// @dev In a block before the first swap, both values are computed from the current `slot0` without writing, and
    /// equal what that swap stores (`fresh` is false). Reverts `PoolNotInitialized` for a pool with no price.
    /// V2-04's drift check must compare `snap * 2^16` with the stored `emaTickX` in fixed point, not these ticks.
    function anchorOf(PoolId poolId) external view returns (int24 snapTick, int24 emaTick, bool fresh) {
        AnchorLib.Anchor memory a = _anchors[poolId];
        if (a.lastBlock >= block.number) return (a.snapTick, AnchorLib.emaTick(a.emaTickX), true);
        a = AnchorLib.next(a, _currentTick(poolId), block.timestamp, block.number, EMA_HALF_LIFE);
        return (a.snapTick, AnchorLib.emaTick(a.emaTickX), false);
    }

    /// @notice STUB (V2-04 step 1).
    function anchorOfX(PoolId) external view returns (int24 snapTick, int56 emaTickX, bool fresh) {}

    /// @notice Called by the PoolManager before a swap. Records the anchor on the first swap of a block, then returns
    /// a zero delta and no LP-fee override: the pool fills the whole swap.
    /// @dev Only the PoolManager may call. `hookData` and the sender are ignored.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        PoolId id = key.toId();
        AnchorLib.Anchor memory a = _anchors[id];
        if (a.lastBlock < block.number) {
            a = AnchorLib.next(a, _currentTick(id), block.timestamp, block.number, EMA_HALF_LIFE);
            _anchors[id] = a;
            emit AnchorUpdated(id, a.snapTick, a.emaTickX, a.lastTimestamp);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _currentTick(PoolId id) private view returns (int24 tick) {
        uint160 sqrtPriceX96;
        (sqrtPriceX96, tick,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
    }

    /// @notice Not implemented: always reverts `HookNotImplemented`. Anyone may call it, to no effect; the
    /// PoolManager never does, because this hook's address flags are off.
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @notice Not implemented: always reverts `HookNotImplemented`. Anyone may call it, to no effect; the
    /// PoolManager never does, because this hook's address flags are off.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @notice Not implemented: always reverts `HookNotImplemented`. Anyone may call it, to no effect; the
    /// PoolManager never does, because this hook's address flags are off.
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @notice Not implemented: always reverts `HookNotImplemented`. Anyone may call it, to no effect; the
    /// PoolManager never does, because this hook's address flags are off.
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @notice Not implemented: always reverts `HookNotImplemented`. Anyone may call it, to no effect; the
    /// PoolManager never does, because this hook's address flags are off.
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @notice Not implemented: always reverts `HookNotImplemented`. Anyone may call it, to no effect; the
    /// PoolManager never does, because this hook's address flags are off.
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @notice Not implemented: always reverts `HookNotImplemented`. Anyone may call it, to no effect; the
    /// PoolManager never does, because this hook's address flags are off.
    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    /// @notice Not implemented: always reverts `HookNotImplemented`. Anyone may call it, to no effect; the
    /// PoolManager never does, because this hook's address flags are off.
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @notice Not implemented: always reverts `HookNotImplemented`. Anyone may call it, to no effect; the
    /// PoolManager never does, because this hook's address flags are off.
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
