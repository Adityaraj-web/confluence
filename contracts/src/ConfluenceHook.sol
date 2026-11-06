// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast as OZSafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/src/libs/TakerTraits.sol";

/// @title ConfluenceHook
/// @notice Uniswap v4 hook whose pool depth comes from a maker's 1inch Aqua strategy.
/// F05: on an exact-input swap with a hint `a` in `hookData`, `beforeSwap` fills `a` of the input from the
/// registered maker order on the canonical router, and the pool curve fills the rest. Every other swap gets a zero
/// delta and is pool-only. Holds no funds between swaps and has no owner powers over user funds.
/// @dev Implements `IHooks` directly: v4-periphery at lib/v4-periphery no longer ships `BaseHook` (D-17).
/// Callbacks other than `beforeSwap` revert; the PoolManager never calls them because the address flags are off.
contract ConfluenceHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using OZSafeCast for int256;
    using CurrencySettler for Currency;

    /// @dev `beforeSwap` was called by an address other than the PoolManager.
    error NotPoolManager();
    /// @dev The caller is not the maker of the order.
    error NotMaker();
    /// @dev No order is registered for this pool.
    error NoOrder();
    /// @dev A hook callback this contract does not implement.
    error HookNotImplemented();

    // F06 skip reasons. These are never thrown: their encodings are the `reason` of `AquaSkipped` when the hook
    // skips the Aqua leg before calling the router. A router revert is reported with the router's own revert data.

    /// @dev Skip reason: the swap is exact output; phase 1 handles exact input only (D-08).
    error ExactOutputNotSupported();
    /// @dev Skip reason: the hint is larger than the swap's input amount.
    error HintAboveAmount();
    /// @dev Skip reason: the hint does not fit in an `int128`, the width of a `BeforeSwapDelta` half.
    error HintTooLarge();
    /// @dev Skip reason: the PoolManager holds less of the input token than the hint, so `take` would revert.
    error PoolManagerShort(uint256 available);
    /// @dev Skip reason: too little gas is left to run the router and still unwind and finish the swap.
    error InsufficientGas(uint256 gasLeft);

    /// @notice A maker registered `orderHash` as the active order for `poolId`.
    event OrderRegistered(PoolId indexed poolId, address indexed maker, bytes32 orderHash);
    /// @notice A maker removed the active order for `poolId`.
    event OrderUnregistered(PoolId indexed poolId, address indexed maker);
    /// @notice The Aqua leg of a swap: `amountIn` of the input went to the maker's strategy for `amountOut`.
    event AquaFill(PoolId indexed poolId, address indexed maker, uint256 amountIn, uint256 amountOut);
    /// @notice The hook was asked for an Aqua leg (a non-zero 32-byte hint) and skipped it; the pool fills the whole
    /// swap. `reason` is an ABI-encoded custom error: this contract's own skip reasons, or the router's revert data
    /// (trimmed to a fixed length).
    event AquaSkipped(PoolId indexed poolId, bytes reason);

    /// @notice The Uniswap v4 PoolManager this hook serves.
    IPoolManager public immutable poolManager;
    /// @notice The canonical AquaSwapVMRouter: the taker's counterparty and the contract that pulls the hook's input.
    address public immutable router;

    /// @dev One active maker order per pool (D-09).
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

    /// @notice Called by the PoolManager before a swap. Fills the hinted part of an exact-input swap from the
    /// registered Aqua order; returns a zero delta (pool-only) when there is nothing to fill.
    /// @dev Only the PoolManager may call. No try/catch yet: a failing router call reverts the swap (F06 adds it).
    /// Skipped, with no `take` and no router call, when: the swap is exact output; `hookData` is not exactly 32
    /// bytes; the hint is 0; the hint exceeds the swap amount; or no order is registered for the pool.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified >= 0 || hookData.length != 32) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 a = abi.decode(hookData, (uint256));
        // |amountSpecified| without overflowing at int256.min.
        uint256 amountIn = (-(params.amountSpecified + 1)).toUint256() + 1;
        if (a == 0 || a > amountIn) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        PoolId id = key.toId();
        ISwapVM.Order memory order = _orders[id];
        if (order.maker == address(0)) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 b = _fill(key, params.zeroForOne, a, order);
        // `b` is only known after the router call, and the PoolManager is locked against re-entry during it.
        // forge-lint: disable-next-line(reentrancy-events)
        emit AquaFill(id, order.maker, a, b);

        // Exact input: specified = +a (input consumed), unspecified = -b (output provided) (D-17).
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(a.toInt128(), -b.toInt128()), 0);
    }

    /// @dev Steps 4-8 of ARCHITECTURE section 3: take `a` of the input, pay the router for it, run Priya's order
    /// with this hook as the taker, and settle the output the router sent here. `b` is the router's return value.
    function _fill(PoolKey calldata key, bool zeroForOne, uint256 a, ISwapVM.Order memory order)
        private
        returns (uint256 b)
    {
        (Currency currencyIn, Currency currencyOut) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        address tokenIn = Currency.unwrap(currencyIn);

        currencyIn.take(poolManager, address(this), a, false);

        // The router is what calls transferFrom on the taker (D-02), so it gets the approval, for exactly `a`.
        IERC20(tokenIn).forceApprove(router, a);
        // Only `b` is used: the router's own check makes the amount in equal `a` (TakerTraits.sol:179).
        // forge-lint: disable-next-line(unused-return)
        (, b,) = ISwapVM(router).swap(order, tokenIn, Currency.unwrap(currencyOut), a, _takerData());
        IERC20(tokenIn).forceApprove(router, 0);

        currencyOut.settle(poolManager, address(this), b, false);
    }

    /// @dev Taker data as in `TakerHelper`: this hook is the taker, exact input, the router pulls the input and
    /// pushes it into Aqua (`useTransferFromAndAquaPush`), the output lands here (`to` zero), and the minimum
    /// output is 1. Real slippage protection is the trader's price limit and the band.
    function _takerData() private view returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: address(this),
                isExactIn: true,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: true,
                threshold: abi.encode(uint256(1)),
                to: address(0),
                deadline: 0,
                hasPreTransferInCallback: false,
                hasPreTransferOutCallback: false,
                preTransferInHookData: "",
                postTransferInHookData: "",
                preTransferOutHookData: "",
                postTransferOutHookData: "",
                preTransferInCallbackData: "",
                preTransferOutCallbackData: "",
                instructionsArgs: "",
                signature: ""
            })
        );
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
