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
contract ConfluenceHookV1 is IHooks {
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
    /// @dev `registerOrder` was given an `order.data` of `length` bytes, more than `max` (`MAX_ORDER_DATA_BYTES`).
    error OrderDataTooLarge(uint256 length, uint256 max);

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

    /// @notice The most revert data of a failed router call that `AquaSkipped` carries.
    uint256 public constant MAX_REASON_BYTES = 256;
    /// @notice Gas the hook keeps back when it calls the router: the router gets everything else. If the router
    /// reverts or runs out of gas, this is what is left to unwind and to finish the rest of the swap (the pool leg
    /// and the swap router's settlement), which the 63/64 rule alone would not leave.
    /// @dev Measured (D-20), against a strategy that burns all the gas it is given and against a legitimate fill, over
    /// 52 transaction gas limits from 285,000 to 3,000,000: 105,000 is the smallest reserve at which the swap never
    /// reverts where the pool alone would pass (100,000 reverts at limits between 335,000 and 405,000). 150,000 is
    /// that plus 43%. The measurement used v4-core's `PoolSwapTest` as the swap router and a pool leg that crosses no
    /// initialised tick; a swap router that does more after `beforeSwap`, or a pool leg that crosses ticks, needs
    /// more. A reserve measured at one gas limit is not enough: the call frames above the hook keep 1/64 of their
    /// gas each, which helps a large limit and not a small one.
    uint256 public constant AQUA_GAS_RESERVE = 150_000;
    /// @notice The gas a legitimate Aqua fill needs inside the router call. Below `AQUA_GAS_RESERVE` plus this, the
    /// hook skips the Aqua leg instead of starting a call that could not finish.
    /// @dev Measured (D-20): the router call of `test_F05_fullAquaFill` uses 152,432 gas, and of
    /// `test_F05_reverseDirection` 153,418; this is the larger rounded up to the next 10,000. The gas the hook spends
    /// before the call (`take`, `approve`) is not counted, so within that distance of the threshold the call can still
    /// run out of gas; that is caught like any other router failure and the pool fills the swap.
    uint256 public constant MIN_AQUA_GAS = 160_000;
    /// @notice The most gas the hook forwards to the router, however much the transaction has: four times
    /// `MIN_AQUA_GAS`, 640,000. `registerOrder` accepts any maker (D-18), so a registered strategy can burn all the
    /// gas it is given; this bounds what a trader can lose to that, instead of the whole gas limit.
    uint256 public constant MAX_AQUA_GAS = 4 * MIN_AQUA_GAS;

    /// @notice The longest `order.data`, in bytes, that `registerOrder` accepts.
    /// @dev Priya's order measures 118 bytes (6 fee + 2 curve + 110 Extruction); this is four times that (472)
    /// rounded up to 512, which leaves room for a richer program. `beforeSwap` copies the stored order out of storage
    /// on every hinted swap before its gas check and the capped router call, so an unbounded `data` could run a
    /// hinted swap out of gas where a pool-only swap would pass (D-20).
    uint256 public constant MAX_ORDER_DATA_BYTES = 512;

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
    /// @dev Only `order.maker` may call. Reverts `OrderDataTooLarge` if `order.data` is longer than
    /// `MAX_ORDER_DATA_BYTES`, so what `beforeSwap` loads on every hinted swap is bounded (D-20).
    function registerOrder(PoolKey calldata key, ISwapVM.Order calldata order) external {
        if (msg.sender != order.maker) revert NotMaker();
        if (order.data.length > MAX_ORDER_DATA_BYTES) {
            revert OrderDataTooLarge(order.data.length, MAX_ORDER_DATA_BYTES);
        }
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
    /// @dev Only the PoolManager may call. A swap that did not ask for an Aqua leg (`hookData` not exactly 32 bytes,
    /// or a hint of 0) is pool-only and silent. A swap that did ask (a non-zero 32-byte hint) and is skipped before
    /// any `take` or router call emits `AquaSkipped` with one of these reasons, checked in this order: exact output
    /// (`ExactOutputNotSupported`); the hint exceeds the swap amount (`HintAboveAmount`); the hint does not fit an
    /// `int128` (`HintTooLarge`); no order for the pool (`NoOrder`); the PoolManager holds less of the input token
    /// than the hint (`PoolManagerShort`, so `take` cannot revert).
    /// Aqua can never make the swap fail: the router call is inside try/catch (see `_fill`). When it reverts, the
    /// hook returns the input to the PoolManager, emits `AquaSkipped` with the router's revert data, and returns a
    /// zero delta, so the pool fills the whole swap.
    /// The one cast outside the try/catch is `b.toInt128()` after a successful router call. It is accepted: the band
    /// holds `b` to roughly `a` times the pool price, and `a` is already capped at int128 max, so `b` overflows only
    /// at an absurd pool price.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (hookData.length != 32) return _poolOnly();
        uint256 a = abi.decode(hookData, (uint256));
        if (a == 0) return _poolOnly();

        PoolId id = key.toId();
        if (params.amountSpecified >= 0) return _skipped(id, abi.encodeWithSelector(ExactOutputNotSupported.selector));
        // |amountSpecified| without overflowing at int256.min.
        uint256 amountIn = (-(params.amountSpecified + 1)).toUint256() + 1;
        if (a > amountIn) return _skipped(id, abi.encodeWithSelector(HintAboveAmount.selector));
        // int128 max, written as a shift so no cast is needed: the largest `a` that fits a `BeforeSwapDelta` half.
        if (a > type(uint128).max >> 1) return _skipped(id, abi.encodeWithSelector(HintTooLarge.selector));

        ISwapVM.Order memory order = _orders[id];
        if (order.maker == address(0)) return _skipped(id, abi.encodeWithSelector(NoOrder.selector));

        uint256 available = (params.zeroForOne ? key.currency0 : key.currency1).balanceOf(address(poolManager));
        if (available < a) return _skipped(id, abi.encodeWithSelector(PoolManagerShort.selector, available));

        uint256 gasLeft = gasleft();
        if (gasLeft < AQUA_GAS_RESERVE + MIN_AQUA_GAS) {
            return _skipped(id, abi.encodeWithSelector(InsufficientGas.selector, gasLeft));
        }

        (bool ok, uint256 b, bytes memory reason) = _fill(key, params.zeroForOne, a, order);
        if (!ok) return _skipped(id, reason);
        // `b` is only known after the router call, and the PoolManager is locked against re-entry during it.
        // forge-lint: disable-next-line(reentrancy-events)
        emit AquaFill(id, order.maker, a, b);

        // Exact input: specified = +a (input consumed), unspecified = -b (output provided) (D-17).
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(a.toInt128(), -b.toInt128()), 0);
    }

    /// @dev The return of a swap the pool fills alone: zero delta.
    function _poolOnly() private pure returns (bytes4, BeforeSwapDelta, uint24) {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Report that the Aqua leg was skipped for `id`, then return the pool-only zero delta.
    function _skipped(PoolId id, bytes memory reason) private returns (bytes4, BeforeSwapDelta, uint24) {
        // For a router failure the reason is only known after the call, and the PoolManager is locked against
        // re-entry during it.
        // forge-lint: disable-next-line(reentrancy-events)
        emit AquaSkipped(id, reason);
        return _poolOnly();
    }

    /// @dev Steps 4-8 of ARCHITECTURE section 3, with the unwind of F06: take `a` of the input, pay the router for
    /// it, run Priya's order with this hook as the taker, and settle the output the router sent here. `b` is the
    /// router's return value.
    /// If the router call reverts for any reason (band breach, docked strategy, revoked approval, short wallet, lock
    /// re-entry, out of gas), everything the router did is undone with it, so the hook holds exactly the `a` it took:
    /// the approval is reset and `a` is settled back to the PoolManager, `ok` is false and `reason` is the router's
    /// revert data, trimmed to `MAX_REASON_BYTES`. Only the router call is inside the try; a failure of the
    /// settlement after it reverts the swap, as does a malformed router return.
    function _fill(PoolKey calldata key, bool zeroForOne, uint256 a, ISwapVM.Order memory order)
        private
        returns (bool ok, uint256 b, bytes memory reason)
    {
        (Currency currencyIn, Currency currencyOut) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        address tokenIn = Currency.unwrap(currencyIn);

        currencyIn.take(poolManager, address(this), a, false);

        // The router is what calls transferFrom on the taker (D-02), so it gets the approval, for exactly `a`.
        IERC20(tokenIn).forceApprove(router, a);
        // The router gets all the gas except `AQUA_GAS_RESERVE`, and never more than `MAX_AQUA_GAS`. The reserve means
        // a revert or an out-of-gas inside the router is caught here and the hook still has the gas to unwind and to
        // let the rest of the swap run; without it the 63/64 rule would leave only about 1/64 of the gas at each call
        // level. The maximum bounds what a gas-burning strategy can cost the trader. Built first, so the taker data's
        // cost is not in the cap.
        bytes memory takerData = _takerData();
        uint256 gasNow = gasleft();
        uint256 routerGas = gasNow > AQUA_GAS_RESERVE ? gasNow - AQUA_GAS_RESERVE : 0;
        if (routerGas > MAX_AQUA_GAS) routerGas = MAX_AQUA_GAS;
        // Only `b` is used: the router's own check makes the amount in equal `a` (TakerTraits.sol:179).
        try ISwapVM(router).swap{gas: routerGas}(order, tokenIn, Currency.unwrap(currencyOut), a, takerData) returns (
            uint256, uint256 amountOut, bytes32
        ) {
            ok = true;
            b = amountOut;
        } catch {
            reason = _revertData();
        }
        IERC20(tokenIn).forceApprove(router, 0);

        if (ok) currencyOut.settle(poolManager, address(this), b, false);
        else currencyIn.settle(poolManager, address(this), a, false);
    }

    /// @dev The revert data of the call that just failed, at most `MAX_REASON_BYTES` of it. Copying only a bounded
    /// prefix means a maker-chosen Extruction cannot use a huge revert to run the swap out of gas (`registerOrder`
    /// accepts any maker, D-18). Must be called right after the failing call, before any other call.
    function _revertData() private pure returns (bytes memory reason) {
        uint256 n = MAX_REASON_BYTES;
        assembly ("memory-safe") {
            if lt(returndatasize(), n) { n := returndatasize() }
        }
        reason = new bytes(n);
        assembly ("memory-safe") {
            returndatacopy(add(reason, 0x20), 0, n)
        }
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
