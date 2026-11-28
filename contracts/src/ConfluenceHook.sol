// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BandGuardV2} from "./BandGuardV2.sol";
import {ConfluenceSplitter, LegStatus, Plan} from "./ConfluenceSplitter.sol";
import {ConfluenceSplitterOut} from "./ConfluenceSplitterOut.sol";
import {AnchorLib} from "./libraries/AnchorLib.sol";
import {MakerVenue} from "./libraries/MakerVenue.sol";
import {PlanCheck} from "./libraries/PlanCheck.sol";
import {StrategyTemplate} from "./libraries/StrategyTemplate.sol";

/// @title ConfluenceHook (v2)
/// @notice A Uniswap v4 hook that keeps a block-start price anchor per pool: the `slot0` tick at the block's first
/// swap, and a time-weighted EMA of those snapshots (ARCHITECTURE-v2 section 4). Immutable, ownerless, no admin.
/// V2-07: every exact-input swap is split between the pool and the registered makers with no hint; exact output is
/// pool-only until V2-08.
/// @dev Implements `IHooks` directly (D-17). Callbacks other than `beforeSwap` revert; the PoolManager never calls
/// them because the address flags are off. This hook never calls `PoolManager.swap` itself: the PoolManager skips the
/// hook for a swap whose caller is the hook (`Hooks.sol:252`), which would bypass the anchor update (D-31).
contract ConfluenceHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using ProtocolFeeLibrary for uint24;

    /// @dev `beforeSwap` was called by an address other than the PoolManager.
    error NotPoolManager();
    /// @dev `beforeSwap`, `register`, `unregister` or `evict` was entered while a swap's leg stage is running (D-38).
    error Reentered();
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
    /// @dev A constructor splitter is the zero address or has no code, or both are the same address.
    error InvalidSplitter();
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
        PoolId indexed poolId,
        address indexed maker,
        bytes32 strategyHash,
        StrategyTemplate.Params params,
        uint256 depth
    );
    /// @notice A maker removed its own slot, or replaced its strategy.
    event MakerUnregistered(PoolId indexed poolId, address indexed maker, bytes32 strategyHash);
    /// @notice A slot was emptied by someone other than its maker.
    event MakerEvicted(PoolId indexed poolId, address indexed maker, bytes32 strategyHash, EvictReason reason);

    /// @notice One registry slot's part in a swap: its leg's input and output (zero when it has none) and a
    /// `LegStatus` code.
    struct Leg {
        bytes32 strategyHash;
        uint256 amountIn;
        uint256 amountOut;
        uint8 status;
    }

    /// @notice One swap, exact input or exact output (`exactIn`), on a pool with registered makers or none (ARCHITECTURE-v2 section 7). `legs` has one
    /// entry per registry slot, in slot order. `sqrtPriceX96`, `liquidity` and `swapFee` are the pool's before the
    /// swap; `swapFee` is v4's combined fee for the direction, in pips.
    event ConfluenceSwap(
        PoolId indexed poolId,
        bool zeroForOne,
        bool exactIn,
        int256 amountSpecified,
        int24 snapTick,
        int24 emaTick,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint24 swapFee,
        Leg[] legs
    );

    /// @notice The anchor of `poolId` was recorded: the first swap of a new block. `emaTickX` is tick x 2^16.
    event AnchorUpdated(PoolId indexed poolId, int24 snapTick, int56 emaTickX, uint40 timestamp);

    /// @notice The Uniswap v4 PoolManager this hook serves.
    IPoolManager public immutable poolManager;
    /// @notice The guard every registered strategy ends with. Deployed by this hook's constructor.
    BandGuardV2 public immutable bandGuard;
    /// @notice The contract that plans each exact-input split (D-35). Immutable; verifying this hook includes verifying it.
    ConfluenceSplitter public immutable splitter;
    /// @notice The contract that plans each exact-output split (D-36, amends D-35). Immutable, likewise.
    ConfluenceSplitterOut public immutable splitterOut;
    /// @notice Half-life of the EMA, in seconds (V2-11 may change it with a DECISIONS entry).
    uint256 public constant EMA_HALF_LIFE = 60;

    /// @notice Most strategies registered per pool (bounds every registry loop).
    uint256 public constant MAX_STRATEGIES = 6;
    /// @notice Most maker legs per swap; the hook refuses a plan with more.
    uint256 public constant MAX_LEGS = PlanCheck.MAX_LEGS;
    /// @notice Smallest leg, in basis points of the swap's input; the hook refuses a plan with a smaller one.
    uint256 public constant MIN_LEG_BPS = PlanCheck.MIN_LEG_BPS;
    /// @notice Gas kept back for the rest of the swap after the plan and after each leg (D-20, re-measured in V2-07).
    uint256 public constant GAS_RESERVE = PlanCheck.GAS_RESERVE;
    /// @notice Least gas a leg is started with.
    uint256 public constant MIN_LEG_GAS = PlanCheck.MIN_LEG_GAS;
    /// @notice Most gas one leg's router call may use.
    uint256 public constant LEG_GAS_CAP = PlanCheck.LEG_GAS_CAP;
    /// @notice Most gas the splitter call may use.
    uint256 public constant PLAN_GAS_CAP = PlanCheck.PLAN_GAS_CAP;
    /// @notice Bytes of an encoded `Plan`; any other return length means pool-only.
    uint256 public constant PLAN_BYTES = PlanCheck.PLAN_BYTES;
    /// @notice Aqua, the same address on Ethereum and Unichain (D-28).
    address public constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    /// @notice The canonical AquaSwapVMRouter v1.0.2, the same address on Ethereum and Unichain (D-28).
    address public constant ROUTER = 0x111111338c5091E8440b67B168bAe16a668AC0De;

    /// @dev Aqua's marker for a docked strategy, and the token count of a template strategy.
    uint8 private constant _DOCKED = 0xff;
    uint8 private constant _TOKENS = 2;
    // casting to 'uint128' is safe: int128 max is positive
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 private constant _MAX_INT128 = uint256(uint128(type(int128).max));
    /// @dev Taker data: ten 16-bit slice indexes, each 32 (only the 32-byte threshold), and the flags.
    /// (2^160 - 1) / (2^16 - 1) is 1 in each of the ten 16-bit fields.
    uint160 private constant _TAKER_SLICES = (type(uint160).max / type(uint16).max) * 32;
    uint16 private constant _TAKER_FLAGS_OUT =
        TakerTraitsLib.IS_STRICT_THRESHOLD_BIT_FLAG | TakerTraitsLib.USE_TRANSFER_FROM_AND_AQUA_PUSH_FLAG;
    uint16 private constant _TAKER_FLAGS = TakerTraitsLib.IS_EXACT_IN_BIT_FLAG | _TAKER_FLAGS_OUT;

    /// @dev One packed slot per pool (slot 0 of this contract is the mapping's base). Keep it first: V2-03's tests
    /// read it with `vm.load`.
    mapping(PoolId => AnchorLib.Anchor) internal _anchors;
    /// @dev At most `MAX_STRATEGIES` entries per pool.
    mapping(PoolId => Slot[]) internal _slots;
    /// @dev Set from before the leg stage's `take` to after its last `settle`: while it is set, a call into
    /// `beforeSwap` or the registry reverts `Reentered`. Transient, so it can never stay set (D-38).
    bool private transient _busy;

    /// @param _poolManager The v4 PoolManager.
    /// @param _splitter The deployed `ConfluenceSplitter` (D-35).
    /// @param _splitterOut The deployed `ConfluenceSplitterOut` (D-36).
    /// @dev Reverts unless the deployed address carries exactly the flags in `getHookPermissions`, and
    /// `InvalidSplitter` for a splitter with no code or the same address given twice.
    constructor(IPoolManager _poolManager, ConfluenceSplitter _splitter, ConfluenceSplitterOut _splitterOut) {
        if (
            address(_splitter).code.length == 0 || address(_splitterOut).code.length == 0
                || address(_splitter) == address(_splitterOut)
        ) revert InvalidSplitter();
        poolManager = _poolManager;
        splitter = _splitter;
        splitterOut = _splitterOut;
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

    /// @notice Register the caller's strategy on this hook's pool. The hook rebuilds the template-T1 order for the
    /// caller from `p` and `key`, and Aqua must report it shipped by the caller for the canonical router, with exactly
    /// the pool's two tokens and not docked. One strategy per maker per pool: calling again replaces the caller's
    /// slot. When all `MAX_STRATEGIES` slots are taken, the newcomer's real depth must be strictly greater than the
    /// smallest slot's, and that slot is evicted. Anyone may call; `msg.sender` is the maker.
    /// @dev Needs the pool's anchor (a swap has happened): depth is priced at the recorded snapshot, never at spot
    /// (D-33). Check order: key, pool exists, anchor, template and Aqua, depth.
    function register(PoolKey calldata key, StrategyTemplate.Params calldata p) external {
        if (_busy) revert Reentered();
        PoolId id = _checkKey(key);
        int24 snap = _snapshotTick(id);
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);

        bytes32 h = StrategyTemplate.strategyHash(
            StrategyTemplate.order(msg.sender, StrategyTemplate.program(p, poolManager, key, address(bandGuard)))
        );
        // Only the token count is needed here; the virtual balance is read by `_state`.
        // forge-lint: disable-next-line(unused-return)
        (, uint8 n0) = IAqua(AQUA).rawBalances(msg.sender, ROUTER, h, c0);
        // forge-lint: disable-next-line(unused-return)
        (, uint8 n1) = IAqua(AQUA).rawBalances(msg.sender, ROUTER, h, c1);
        if (n0 == _DOCKED && n1 == _DOCKED) revert StrategyDocked(h);
        if (n0 != _TOKENS || n1 != _TOKENS) revert StrategyNotShipped(h);

        (uint256 depth,) = _state(c0, c1, msg.sender, h, snap);
        if (depth == 0) revert NoDepth();

        Slot[] storage slots = _slots[id];
        Slot memory slot = Slot({maker: msg.sender, params: p, strategyHash: h});
        (bool own, uint256 at) = _find(slots, msg.sender);
        if (own) {
            // Only STATICCALLs to Aqua and token views run before this event; they cannot reenter.
            // forge-lint: disable-next-line(reentrancy-events)
            emit MakerUnregistered(id, msg.sender, slots[at].strategyHash);
            slots[at] = slot;
        } else if (slots.length < MAX_STRATEGIES) {
            slots.push(slot);
        } else {
            (uint256 idx, uint256 smallest, EvictReason reason) = _smallest(slots, c0, c1, snap);
            if (depth <= smallest) revert DepthTooLow(depth, smallest);
            // Only STATICCALLs to Aqua and token views run before this event; they cannot reenter.
            // forge-lint: disable-next-line(reentrancy-events)
            emit MakerEvicted(id, slots[idx].maker, slots[idx].strategyHash, reason);
            slots[idx] = slot;
        }
        // Only STATICCALLs to Aqua and token views run before this event; they cannot reenter.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MakerRegistered(id, msg.sender, h, p, depth);
    }

    /// @notice Remove the caller's own slot. Only the maker can; nobody else's call changes it.
    /// @dev Reverts `NotRegistered` when the caller has no slot in the pool named by `key`.
    function unregister(PoolKey calldata key) external {
        if (_busy) revert Reentered();
        PoolId id = key.toId();
        Slot[] storage slots = _slots[id];
        (bool found, uint256 at) = _find(slots, msg.sender);
        if (!found) revert NotRegistered(msg.sender);
        bytes32 h = slots[at].strategyHash;
        _remove(slots, at);
        // Only STATICCALLs to Aqua and token views run before this event; they cannot reenter.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MakerUnregistered(id, msg.sender, h);
    }

    /// @notice Remove `maker`'s slot when its strategy is docked or its real depth is zero. Anyone may call; it
    /// reverts `NotEvictable` for a strategy that is shipped and has depth, and `NotRegistered` for an unknown maker.
    function evict(PoolKey calldata key, address maker) external {
        if (_busy) revert Reentered();
        PoolId id = key.toId();
        Slot[] storage slots = _slots[id];
        (bool found, uint256 at) = _find(slots, maker);
        if (!found) revert NotRegistered(maker);
        bytes32 h = slots[at].strategyHash;
        (uint256 depth, bool docked) =
            _state(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), maker, h, _snapshotTick(id));
        EvictReason reason;
        if (docked) reason = EvictReason.DOCKED;
        else if (depth == 0) reason = EvictReason.NO_DEPTH;
        else revert NotEvictable(maker);
        _remove(slots, at);
        // Only STATICCALLs to Aqua and token views run before this event; they cannot reenter.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MakerEvicted(id, maker, h, reason);
    }

    /// @notice The real depth of `maker`'s registered strategy now, in currency1 units at the snapshot price:
    /// per token min(Aqua virtual balance, wallet balance, allowance to Aqua), then `d0 * price + d1`. It ranks slots
    /// within this pool only; a wallet backing strategies in several pools counts fully in each (D-33). Anyone may
    /// call. Reverts `AnchorNotInitialised` before the pool's first swap, and `NotRegistered` for an unknown maker.
    function depthOf(PoolKey calldata key, address maker) external view returns (uint256 depth) {
        PoolId id = key.toId();
        int24 snap = _snapshotTick(id);
        Slot[] storage slots = _slots[id];
        (bool found, uint256 at) = _find(slots, maker);
        if (!found) revert NotRegistered(maker);
        (depth,) =
            _state(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), maker, slots[at].strategyHash, snap);
    }

    /// @notice The registered strategies of a pool, in slot order. Anyone may call.
    function strategiesOf(PoolId poolId) external view returns (Slot[] memory) {
        return _slots[poolId];
    }

    /// @notice Called by the PoolManager before a swap. Records the anchor on the first swap of a block, then splits
    /// the swap between the pool and the registered makers (ARCHITECTURE-v2 section 2), for exact input and for exact
    /// output: the splitter plans, this hook checks the plan, takes the makers' total input from the PoolManager, fills
    /// each leg through the canonical router as the taker inside try/catch, settles back what did not fill and settles
    /// the output, and returns the filled amounts as its delta: (input, -output) for exact input, (-output, input) for
    /// exact output (specified first, D-36). The pool fills the rest. Never an LP-fee override.
    /// @dev Only the PoolManager may call. `hookData` and the sender are ignored. An amount of 0, or beyond int128 max
    /// either way, is pool-only and emits no `ConfluenceSwap`. No maker can make the swap fail: a failed splitter or a
    /// plan that fails a check gives pool-only, a failed leg is settled back (D-35).
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (_busy) revert Reentered();
        PoolId id = key.toId();
        AnchorLib.Anchor memory a = _anchors[id];
        if (a.lastBlock < block.number) {
            a = AnchorLib.next(a, _currentTick(id), block.timestamp, block.number, EMA_HALF_LIFE);
            _anchors[id] = a;
            emit AnchorUpdated(id, a.snapTick, a.emaTickX, a.lastTimestamp);
        }
        BeforeSwapDelta delta = BeforeSwapDeltaLibrary.ZERO_DELTA;
        int256 spec = params.amountSpecified;
        // casting to 'int256' is safe: int128 max fits
        // forge-lint: disable-next-line(unsafe-typecast)
        if (spec != 0 && spec >= -int256(_MAX_INT128) && spec <= int256(_MAX_INT128)) {
            delta = _split(id, key, params, a);
        }
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    /// @dev One swap: plan, check, legs, event. Returns the filled input and output as the delta.
    function _split(PoolId id, PoolKey calldata key, IPoolManager.SwapParams calldata params, AnchorLib.Anchor memory a)
        private
        returns (BeforeSwapDelta)
    {
        bool exactIn = params.amountSpecified < 0;
        // casting to 'uint256' is safe: beforeSwap checked amountSpecified is nonzero and within int128
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        Slot[] storage slots = _slots[id];
        uint256 n = Math.min(slots.length, MAX_STRATEGIES);
        Leg[] memory legs = new Leg[](n);
        uint256 sumIn = 0;
        uint256 sumOut = 0;
        if (n > 0) {
            (uint8 code, Plan memory p) = PlanCheck.plan(
                exactIn ? address(splitter) : address(splitterOut),
                poolManager,
                key,
                params.zeroForOne,
                params.sqrtPriceLimitX96,
                amount,
                a.snapTick,
                a.emaTickX,
                n,
                exactIn
            );
            for (uint256 i; i < n; i++) {
                // casting to 'uint8' is safe: `_checkPlan` bounds every status by LegStatus.MAX_CODE
                // forge-lint: disable-next-line(unsafe-typecast)
                legs[i] = Leg(slots[i].strategyHash, 0, 0, code == LegStatus.FILLED ? uint8(p.status[i]) : code);
            }
            if (code == LegStatus.FILLED) (sumIn, sumOut) = _legs(key, params.zeroForOne, slots, p, legs, exactIn);
        }
        (uint160 sqrtP,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(id);
        uint16 pf = params.zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
        // The legs' external calls are done; the event reports their outcome.
        // forge-lint: disable-start(reentrancy-events)
        emit ConfluenceSwap(
            id,
            params.zeroForOne,
            exactIn,
            params.amountSpecified,
            a.snapTick,
            AnchorLib.emaTick(a.emaTickX),
            sqrtP,
            poolManager.getLiquidity(id),
            pf == 0 ? lpFee : ProtocolFeeLibrary.calculateSwapFee(pf, lpFee),
            legs
        );
        // forge-lint: disable-end(reentrancy-events)
        int128 inDelta = SafeCast.toInt128(SafeCast.toInt256(sumIn));
        int128 outDelta = -SafeCast.toInt128(SafeCast.toInt256(sumOut));
        // The specified side first: the input for exact input, the output for exact output (Hooks.sol:272-278).
        return exactIn ? toBeforeSwapDelta(inDelta, outDelta) : toBeforeSwapDelta(outDelta, inDelta);
    }

    /// @dev Runs the planned legs. Takes their total input once, fills each through the router, then settles back
    /// what did not fill and settles the output received. `legs` holds one entry per slot with the plan's codes.
    function _legs(
        PoolKey calldata key,
        bool zeroForOne,
        Slot[] storage slots,
        Plan memory p,
        Leg[] memory legs,
        bool exactIn
    ) private returns (uint256 sumIn, uint256 sumOut) {
        (Currency cIn, Currency cOut) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        uint256 n = legs.length;
        uint256 planned = 0;
        for (uint256 i; i < n; i++) {
            planned += p.amountIn[i];
        }
        if (planned == 0) return (0, 0);
        // The pool may have to take everything if every leg fails: the plan's own reserve (V2-11, lever 8).
        uint256 reserve = PlanCheck.reserve(p);
        if (gasleft() < reserve + MIN_LEG_GAS) {
            for (uint256 i; i < n; i++) {
                if (p.amountIn[i] > 0) legs[i].status = LegStatus.SKIP_GAS;
            }
            return (0, 0);
        }
        IERC20 tokenOut = IERC20(Currency.unwrap(cOut));
        _busy = true;
        // A failing `take` (a blocklisted hook, a token that refuses) fails every leg and leaves the swap to the pool.
        try poolManager.take(cIn, address(this), planned) {}
        catch {
            _busy = false;
            _refuseAll(p, legs);
            return (0, 0);
        }
        uint256 outBefore = tokenOut.balanceOf(address(this));
        for (uint256 i; i < n; i++) {
            uint256 x = p.amountIn[i];
            if (x == 0) continue;
            (uint8 status, uint256 out) = _fill(key, slots[i], cIn, cOut, x, p.amountOut[i], exactIn, reserve);
            legs[i].status = status;
            if (status == LegStatus.FILLED) {
                (legs[i].amountIn, legs[i].amountOut) = (x, out);
                sumIn += x;
            }
        }
        // The output actually received: a router failure moves nothing, a fill moves exactly its output.
        sumOut = tokenOut.balanceOf(address(this)) - outBefore;
        if (planned > sumIn) _settle(cIn, planned - sumIn);
        if (sumOut > 0) _settle(cOut, sumOut);
        _busy = false;
    }

    /// @dev Marks every planned leg `SKIP_REVERT` (the `take` failed, so no leg ran).
    function _refuseAll(Plan memory p, Leg[] memory legs) private pure {
        for (uint256 i; i < legs.length; i++) {
            if (p.amountIn[i] > 0) legs[i].status = LegStatus.SKIP_REVERT;
        }
    }

    /// @dev Pays `amount` of `c` to the PoolManager: sync, transfer, settle. The transfer is `CurrencyLibrary.transfer`
    /// (`Currency.sol:40`), which accepts a token that returns nothing (USDT) as well as one that returns true; v4-core's
    /// test `CurrencySettler.settle` (`CurrencySettler.sol:27-33`) decodes a `bool` and reverts on no return data (D-38).
    function _settle(Currency c, uint256 amount) private {
        poolManager.sync(c);
        c.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    /// @dev One leg: the order rebuilt from the slot (its hash must still be the registered one), `reserve` kept
    /// back, exact approval of the leg's gross input `x`, the router call inside try/catch, approval reset to 0. Exact
    /// input swaps `x` with a strict threshold of the planned output `out`; exact output swaps `out` with a strict
    /// threshold of the planned input `x`: either way the router takes exactly `x` and gives exactly `out`, or reverts.
    /// The revert data is not copied (zero of the 256 bytes the spec allows).
    function _fill(
        PoolKey calldata key,
        Slot storage s,
        Currency cIn,
        Currency cOut,
        uint256 x,
        uint256 out,
        bool exactIn,
        uint256 reserve
    ) private returns (uint8 status, uint256 got) {
        ISwapVM.Order memory o = StrategyTemplate.order(
            s.maker, StrategyTemplate.program(s.params, poolManager, key, address(bandGuard))
        );
        if (StrategyTemplate.strategyHash(o) != s.strategyHash) return (LegStatus.SKIP_UNDERFUNDED, 0);
        uint256 g = gasleft();
        if (g < reserve + MIN_LEG_GAS) return (LegStatus.SKIP_GAS, 0);
        IERC20 tokenIn = IERC20(Currency.unwrap(cIn));
        tokenIn.forceApprove(ROUTER, x);
        status = LegStatus.SKIP_REVERT;
        // forge-lint: disable-start(calls-loop)
        try ISwapVM(ROUTER).swap{gas: Math.min(g - reserve, LEG_GAS_CAP)}(
            o, Currency.unwrap(cIn), Currency.unwrap(cOut), exactIn ? x : out, _takerData(exactIn, exactIn ? out : x)
        ) returns (
            uint256, uint256 amountOut, bytes32
        ) {
            (status, got) = (LegStatus.FILLED, amountOut);
        } catch {}
        // forge-lint: disable-end(calls-loop)
        tokenIn.forceApprove(ROUTER, 0);
    }

    /// @dev A strict threshold `threshold` (exact input: the planned output the fill must give exactly; exact output:
    /// the planned input it must take exactly), the input pulled from this hook and pushed to the maker through Aqua,
    /// the output to this hook, no deadline, hooks or callbacks; the exact-input flag only for exact input. This is
    /// `TakerTraitsLib.build` for those arguments (`TakerTraits.sol:105-160`), written out to save code size (D-35): the
    /// ten slice indexes all end at the 32-byte threshold, then the flags, then the threshold. The tests' mocked-router
    /// calls match the hook's calldata against `TakerTraitsLib.build` byte for byte, in both modes.
    function _takerData(bool exactIn, uint256 threshold) private pure returns (bytes memory) {
        return abi.encodePacked(_TAKER_SLICES, exactIn ? _TAKER_FLAGS : _TAKER_FLAGS_OUT, threshold);
    }

    /// @dev Static key checks, then that the pool exists. Returns the pool id.
    function _checkKey(PoolKey calldata key) private view returns (PoolId id) {
        if (address(key.hooks) != address(this)) revert HooksMismatch(address(key.hooks));
        address c0 = Currency.unwrap(key.currency0);
        if (c0 == address(0)) revert NativeCurrencyUnsupported();
        if (c0 >= Currency.unwrap(key.currency1)) revert CurrenciesOutOfOrder();
        if (key.fee > LPFeeLibrary.MAX_LP_FEE && key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) {
            revert InvalidPoolFee(key.fee);
        }
        if (key.tickSpacing < TickMath.MIN_TICK_SPACING || key.tickSpacing > TickMath.MAX_TICK_SPACING) {
            revert InvalidTickSpacing(key.tickSpacing);
        }
        id = key.toId();
        _currentTick(id); // reverts PoolNotInitialized
    }

    /// @dev The recorded snapshot tick: the `slot0` tick at the start of the last block with a swap. Never spot, and
    /// never the lazy "now" value `anchorOf` returns before the block's first swap (D-33).
    function _snapshotTick(PoolId id) private view returns (int24) {
        AnchorLib.Anchor memory a = _anchors[id];
        if (a.lastBlock == 0) revert AnchorNotInitialised();
        return a.snapTick;
    }

    /// @dev Real depth of a strategy and whether it is docked (both tokens report 0xff). A strategy that does not
    /// report the two-token count has depth zero.
    function _state(address c0, address c1, address maker, bytes32 h, int24 snap)
        private
        view
        returns (uint256 depth, bool docked)
    {
        // Bounded by `MAX_STRATEGIES` (`_smallest`); the calls are STATICCALLs to Aqua and token views.
        // forge-lint: disable-next-line(calls-loop)
        (uint256 v0, uint8 n0) = IAqua(AQUA).rawBalances(maker, ROUTER, h, c0);
        // forge-lint: disable-next-line(calls-loop)
        (uint256 v1, uint8 n1) = IAqua(AQUA).rawBalances(maker, ROUTER, h, c1);
        if (n0 == _DOCKED && n1 == _DOCKED) return (0, true);
        if (n0 != _TOKENS || n1 != _TOKENS) return (0, false);
        depth = StrategyTemplate.depthValue(_real(c0, maker, v0), _real(c1, maker, v1), snap);
    }

    /// @dev What Aqua can pull of one token: the virtual balance, capped by the wallet and by the allowance to Aqua.
    ///      The same function V2-06's `MakerVenue` uses for a maker's cap (carry-over 1).
    function _real(address token, address maker, uint256 virtualBalance) private view returns (uint256) {
        return MakerVenue.real(token, maker, virtualBalance);
    }

    /// @dev The slot with the smallest live depth (the lowest index on a tie) and why it can go.
    function _smallest(Slot[] storage slots, address c0, address c1, int24 snap)
        private
        view
        returns (uint256 idx, uint256 smallest, EvictReason reason)
    {
        uint256 n = Math.min(slots.length, MAX_STRATEGIES);
        smallest = type(uint256).max;
        bool docked = false;
        for (uint256 i; i < n; i++) {
            (uint256 d, bool dk) = _state(c0, c1, slots[i].maker, slots[i].strategyHash, snap);
            if (d < smallest) (idx, smallest, docked) = (i, d, dk);
        }
        reason = docked ? EvictReason.DOCKED : (smallest == 0 ? EvictReason.NO_DEPTH : EvictReason.DISPLACED);
    }

    function _find(Slot[] storage slots, address maker) private view returns (bool found, uint256 at) {
        uint256 n = Math.min(slots.length, MAX_STRATEGIES);
        for (uint256 i; i < n; i++) {
            if (slots[i].maker == maker) return (true, i);
        }
    }

    /// @dev Swap-and-pop; slot order is not meaningful.
    function _remove(Slot[] storage slots, uint256 at) private {
        uint256 last = slots.length - 1;
        if (at != last) slots[at] = slots[last];
        slots.pop();
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
