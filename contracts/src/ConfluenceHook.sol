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

import {BandGuardV2} from "./BandGuardV2.sol";
import {AnchorLib} from "./libraries/AnchorLib.sol";
import {StrategyTemplate} from "./libraries/StrategyTemplate.sol";

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

    /// @dev `register` was given a `key.hooks` that is not this hook.
    error HooksMismatch(address hooks);
    /// @dev `currency0` is not strictly below `currency1`.
    error CurrenciesOutOfOrder();
    /// @dev A native-currency pool: Aqua holds no native balances.
    error NativeCurrencyUnsupported();
    /// @dev A fee above `MAX_LP_FEE` that is not the dynamic-fee flag.
    error InvalidPoolFee(uint24 fee);
    /// @dev A tick spacing outside v4's [1, 32767].
    error InvalidTickSpacing(int24 tickSpacing);
    /// @dev The pool has never had a swap: no recorded snapshot to price depth with (D-33).
    error AnchorNotInitialised();
    /// @dev Aqua does not report this strategy as shipped by the maker for the canonical router with the pair.
    error StrategyNotShipped(bytes32 strategyHash);
    /// @dev The strategy was docked.
    error StrategyDocked(bytes32 strategyHash);
    /// @dev The strategy could not fill anything now: its real depth is zero.
    error NoDepth();
    /// @dev The registry is full and the newcomer's depth does not exceed the smallest slot's.
    error DepthTooLow(uint256 depth, uint256 smallest);
    /// @dev The maker has no slot in this pool.
    error NotRegistered(address maker);
    /// @dev The slot's strategy is shipped and has depth: nobody may evict it.
    error NotEvictable(address maker);

    /// @notice Why a slot was emptied by `evict` or by a newcomer.
    enum EvictReason {
        DISPLACED,
        DOCKED,
        NO_DEPTH
    }

    /// @notice One registered maker.
    struct Slot {
        address maker;
        StrategyTemplate.Params params;
        bytes32 strategyHash;
    }

    /// @notice A maker registered a strategy. `depth` is its real depth, in currency1 units at the snapshot price.
    event MakerRegistered(
        PoolId indexed poolId, address indexed maker, bytes32 strategyHash, StrategyTemplate.Params params, uint256 depth
    );
    /// @notice A maker removed its own slot, or replaced its strategy.
    event MakerUnregistered(PoolId indexed poolId, address indexed maker, bytes32 strategyHash);
    /// @notice A slot was emptied by someone other than its maker.
    event MakerEvicted(PoolId indexed poolId, address indexed maker, bytes32 strategyHash, EvictReason reason);

    /// @notice The anchor of `poolId` was recorded: the first swap of a new block. `emaTickX` is tick x 2^16.
    event AnchorUpdated(PoolId indexed poolId, int24 snapTick, int56 emaTickX, uint40 timestamp);

    /// @notice The Uniswap v4 PoolManager this hook serves.
    IPoolManager public immutable poolManager;
    /// @notice The guard every registered strategy ends with. Deployed by this hook's constructor.
    BandGuardV2 public immutable bandGuard;
    /// @notice Half-life of the EMA, in seconds (V2-11 may change it with a DECISIONS entry).
    uint256 public constant EMA_HALF_LIFE = 60;

    /// @notice Most strategies registered per pool (bounds every registry loop).
    uint256 public constant MAX_STRATEGIES = 6;
    /// @notice Aqua, the same address on Ethereum and Unichain (D-28).
    address public constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    /// @notice The canonical AquaSwapVMRouter v1.0.2, the same address on Ethereum and Unichain (D-28).
    address public constant ROUTER = 0x111111338c5091E8440b67B168bAe16a668AC0De;

    /// @dev One packed slot per pool (slot 0 of this contract is the mapping's base). Keep it first: V2-03's tests
    /// read it with `vm.load`.
    mapping(PoolId => AnchorLib.Anchor) internal _anchors;
    /// @dev At most `MAX_STRATEGIES` entries per pool.
    mapping(PoolId => Slot[]) internal _slots;

    /// @param _poolManager The v4 PoolManager.
    /// @dev Reverts unless the deployed address carries exactly the flags in `getHookPermissions`.
    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        bandGuard = new BandGuardV2();
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
    /// For the drift check use `anchorOfX`, which does not round.
    function anchorOf(PoolId poolId) external view returns (int24 snapTick, int24 emaTick, bool fresh) {
        AnchorLib.Anchor memory a;
        (a, fresh) = _anchorNow(poolId);
        return (a.snapTick, AnchorLib.emaTick(a.emaTickX), fresh);
    }

    /// @notice The same anchor as `anchorOf`, with the EMA unrounded: `emaTickX` is the tick times 2^16, exactly as
    /// stored. BandGuardV2's drift check compares it with `snapTick * 2^16`, so rounding never decides a refusal
    /// (D-31, D-32). Anyone may call.
    /// @dev Computed by the same lazy path as `anchorOf`; reverts `PoolNotInitialized` for a pool with no price.
    function anchorOfX(PoolId poolId) external view returns (int24 snapTick, int56 emaTickX, bool fresh) {
        AnchorLib.Anchor memory a;
        (a, fresh) = _anchorNow(poolId);
        return (a.snapTick, a.emaTickX, fresh);
    }

    /// @notice STUB (red phase).
    function register(PoolKey calldata, StrategyTemplate.Params calldata) external pure {
        revert HookNotImplemented();
    }

    /// @notice STUB (red phase).
    function unregister(PoolKey calldata) external pure {
        revert HookNotImplemented();
    }

    /// @notice STUB (red phase).
    function evict(PoolKey calldata, address) external pure {
        revert HookNotImplemented();
    }

    /// @notice STUB (red phase).
    function depthOf(PoolKey calldata, address) external pure returns (uint256) {
        revert HookNotImplemented();
    }

    /// @notice The registered strategies of a pool, in slot order. Anyone may call.
    function strategiesOf(PoolId poolId) external view returns (Slot[] memory) {
        return _slots[poolId];
    }

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

    /// @dev What the block's first swap stores, or what is stored if a swap already ran this block.
    function _anchorNow(PoolId poolId) private view returns (AnchorLib.Anchor memory a, bool fresh) {
        a = _anchors[poolId];
        if (a.lastBlock >= block.number) return (a, true);
        a = AnchorLib.next(a, _currentTick(poolId), block.timestamp, block.number, EMA_HALF_LIFE);
        return (a, false);
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
