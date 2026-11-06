// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

/// @title ConfluenceHook
/// @notice Uniswap v4 hook whose pool depth will come from a maker's 1inch Aqua strategy.
/// F04 skeleton: final permissions and storage, no Aqua work. `beforeSwap` returns a zero delta, so the
/// pool curve fills every swap. Holds no funds and has no owner powers over user funds.
/// @dev Implements `IHooks` directly: v4-periphery at lib/v4-periphery no longer ships `BaseHook` (D-17).
/// Callbacks other than `beforeSwap` revert; the PoolManager never calls them because the address flags are off.
contract ConfluenceHook is IHooks {
    using PoolIdLibrary for PoolKey;

    /// @dev `beforeSwap` was called by an address other than the PoolManager.
    error NotPoolManager();
    /// @dev The caller is not the maker of the order.
    error NotMaker();
    /// @dev No order is registered for this pool.
    error NoOrder();
    /// @dev A hook callback this contract does not implement.
    error HookNotImplemented();

    /// @notice A maker registered `orderHash` as the active order for `poolId`.
    event OrderRegistered(PoolId indexed poolId, address indexed maker, bytes32 orderHash);
    /// @notice A maker removed the active order for `poolId`.
    event OrderUnregistered(PoolId indexed poolId, address indexed maker);

    /// @notice The Uniswap v4 PoolManager this hook serves.
    IPoolManager public immutable poolManager;
    /// @notice The canonical AquaSwapVMRouter. Unused until F05.
    address public immutable router;

    /// @dev One active maker order per pool (D-09). F04 stores it without using it.
    mapping(PoolId => ISwapVM.Order) internal _orders;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param _poolManager The v4 PoolManager.
    /// @param _router The canonical AquaSwapVMRouter v1.0.2.
    /// @dev Reverts unless the deployed address carries exactly the flags in `getHookPermissions`.
    constructor(IPoolManager _poolManager, address _router) {
        poolManager = _poolManager;
        router = _router;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice The hook's permissions: `beforeSwap` and `beforeSwapReturnDelta` only. Anyone may call.
    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true;
    }

    /// @notice Register `order` as the active order for the pool `key`, replacing any earlier one.
    /// @dev Only `order.maker` may call.
    function registerOrder(PoolKey calldata key, ISwapVM.Order calldata order) external {
        if (msg.sender != order.maker) revert NotMaker();
        PoolId id = key.toId();
        _orders[id] = order;
        emit OrderRegistered(id, order.maker, keccak256(abi.encode(order)));
    }

    /// @notice Remove the active order for the pool `key`.
    /// @dev Only the registered order's maker may call.
    function unregisterOrder(PoolKey calldata key) external {
        PoolId id = key.toId();
        address maker = _orders[id].maker;
        if (maker == address(0)) revert NoOrder();
        if (msg.sender != maker) revert NotMaker();
        delete _orders[id];
        emit OrderUnregistered(id, maker);
    }

    /// @notice The active order for `id`; `maker` is zero when none is registered. Anyone may call.
    function orderOf(PoolId id) external view returns (ISwapVM.Order memory) {
        return _orders[id];
    }

    /// @notice Called by the PoolManager before a swap. F04: returns a zero delta and no fee override.
    /// @dev Only the PoolManager may call.
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ---- callbacks the hook does not use: all revert, so anyone may call them to no effect ----

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
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

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
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

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
