// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
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
import {AnchorLib} from "./libraries/AnchorLib.sol";
import {MakerVenue} from "./libraries/MakerVenue.sol";
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
    using CurrencySettler for Currency;
    using ProtocolFeeLibrary for uint24;

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
    /// @dev The constructor's splitter is the zero address or has no code.
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

    /// @notice One exact-input swap on a pool with registered makers or none (ARCHITECTURE-v2 section 7). `legs` has one
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
    /// @notice The contract that plans each split (D-35). Immutable; verifying this hook includes verifying it.
    ConfluenceSplitter public immutable splitter;
    /// @notice Half-life of the EMA, in seconds (V2-11 may change it with a DECISIONS entry).
    uint256 public constant EMA_HALF_LIFE = 60;

    /// @notice Most strategies registered per pool (bounds every registry loop).
    uint256 public constant MAX_STRATEGIES = 6;
    /// @notice Most maker legs per swap; the hook refuses a plan with more.
    uint256 public constant MAX_LEGS = 3;
    /// @notice Smallest leg, in basis points of the swap's input; the hook refuses a plan with a smaller one.
    uint256 public constant MIN_LEG_BPS = 50;
    /// @notice Gas kept back for the rest of the swap after the plan and after each leg (D-20, re-measured in V2-07).
    uint256 public constant GAS_RESERVE = 150_000;
    /// @notice Least gas a leg is started with.
    uint256 public constant MIN_LEG_GAS = 160_000;
    /// @notice Most gas one leg's router call may use.
    uint256 public constant LEG_GAS_CAP = 640_000;
    /// @notice Most gas the splitter call may use.
    uint256 public constant PLAN_GAS_CAP = 1_500_000;
    /// @notice Bytes of an encoded `Plan`; any other return length means pool-only.
    uint256 public constant PLAN_BYTES = 36 * 32;
    /// @notice Aqua, the same address on Ethereum and Unichain (D-28).
    address public constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    /// @notice The canonical AquaSwapVMRouter v1.0.2, the same address on Ethereum and Unichain (D-28).
    address public constant ROUTER = 0x111111338c5091E8440b67B168bAe16a668AC0De;

    /// @dev Aqua's marker for a docked strategy, and the token count of a template strategy.
    uint8 private constant _DOCKED = 0xff;
    uint8 private constant _TOKENS = 2;
    uint256 private constant _BPS = 10_000;
    // casting to 'uint128' is safe: int128 max is positive
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 private constant _MAX_INT128 = uint256(uint128(type(int128).max));
    /// @dev Taker data: ten 16-bit slice indexes, each 32 (only the 32-byte threshold), and the flags.
    /// (2^160 - 1) / (2^16 - 1) is 1 in each of the ten 16-bit fields.
    uint160 private constant _TAKER_SLICES = (type(uint160).max / type(uint16).max) * 32;
    uint16 private constant _TAKER_FLAGS = TakerTraitsLib.IS_EXACT_IN_BIT_FLAG
        | TakerTraitsLib.IS_STRICT_THRESHOLD_BIT_FLAG | TakerTraitsLib.USE_TRANSFER_FROM_AND_AQUA_PUSH_FLAG;

    /// @dev One packed slot per pool (slot 0 of this contract is the mapping's base). Keep it first: V2-03's tests
    /// read it with `vm.load`.
    mapping(PoolId => AnchorLib.Anchor) internal _anchors;
    /// @dev At most `MAX_STRATEGIES` entries per pool.
    mapping(PoolId => Slot[]) internal _slots;

    /// @param _poolManager The v4 PoolManager.
    /// @param _splitter The deployed `ConfluenceSplitter` (D-35).
    /// @dev Reverts unless the deployed address carries exactly the flags in `getHookPermissions`, and
    /// `InvalidSplitter` for a splitter with no code.
    constructor(IPoolManager _poolManager, ConfluenceSplitter _splitter) {
        if (address(_splitter).code.length == 0) revert InvalidSplitter();
        poolManager = _poolManager;
        splitter = _splitter;
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

    /// @notice Called by the PoolManager before a swap. Records the anchor on the first swap of a block, then, for
    /// exact input, splits the swap between the pool and the registered makers (ARCHITECTURE-v2 section 2): the
    /// splitter plans, this hook checks the plan, takes the makers' total input from the PoolManager, fills each leg
    /// through the canonical router as the taker inside try/catch, settles back what did not fill and settles the
    /// output, and returns the filled amounts as its delta. The pool fills the rest. Never an LP-fee override.
    /// @dev Only the PoolManager may call. `hookData` and the sender are ignored. Exact output, and an input above
    /// int128 max, are pool-only and emit no `ConfluenceSwap` (V2-08). No maker can make the swap fail: a failed
    /// splitter or a plan that fails a check gives pool-only, a failed leg is settled back (D-35).
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
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
        BeforeSwapDelta delta = BeforeSwapDeltaLibrary.ZERO_DELTA;
        // casting to 'int256' is safe: int128 max fits
        // forge-lint: disable-next-line(unsafe-typecast)
        if (params.amountSpecified < 0 && params.amountSpecified >= -int256(_MAX_INT128)) {
            delta = _split(id, key, params, a);
        }
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    /// @dev One exact-input swap: plan, check, legs, event. Returns the filled input and output as the delta.
    function _split(PoolId id, PoolKey calldata key, IPoolManager.SwapParams calldata params, AnchorLib.Anchor memory a)
        private
        returns (BeforeSwapDelta)
    {
        // casting to 'uint256' is safe: beforeSwap checked -int128 max <= amountSpecified < 0
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount = uint256(-params.amountSpecified);
        Slot[] storage slots = _slots[id];
        uint256 n = Math.min(slots.length, MAX_STRATEGIES);
        Leg[] memory legs = new Leg[](n);
        uint256 sumIn = 0;
        uint256 sumOut = 0;
        if (n > 0) {
            (uint8 code, Plan memory p) = _plan(key, params, amount, a, n);
            for (uint256 i; i < n; i++) {
                // casting to 'uint8' is safe: `_checkPlan` bounds every status by LegStatus.MAX_CODE
                // forge-lint: disable-next-line(unsafe-typecast)
                legs[i] = Leg(slots[i].strategyHash, 0, 0, code == LegStatus.FILLED ? uint8(p.status[i]) : code);
            }
            if (code == LegStatus.FILLED) (sumIn, sumOut) = _legs(key, params.zeroForOne, slots, p, legs);
        }
        (uint160 sqrtP,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(id);
        uint16 pf = params.zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
        // The legs' external calls are done; the event reports their outcome.
        // forge-lint: disable-start(reentrancy-events)
        emit ConfluenceSwap(
            id,
            params.zeroForOne,
            true,
            params.amountSpecified,
            a.snapTick,
            AnchorLib.emaTick(a.emaTickX),
            sqrtP,
            poolManager.getLiquidity(id),
            pf == 0 ? lpFee : ProtocolFeeLibrary.calculateSwapFee(pf, lpFee),
            legs
        );
        // forge-lint: disable-end(reentrancy-events)
        return
            toBeforeSwapDelta(
                SafeCast.toInt128(SafeCast.toInt256(sumIn)), -SafeCast.toInt128(SafeCast.toInt256(sumOut))
            );
    }

    /// @dev Calls the splitter with a gas cap (low-level, so malformed data cannot revert), then checks the plan.
    /// Returns `LegStatus.FILLED` for a plan to run, `SKIP_GAS` or `SKIP_PLAN` for pool-only.
    function _plan(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        uint256 amount,
        AnchorLib.Anchor memory a,
        uint256 n
    ) private view returns (uint8 code, Plan memory p) {
        uint256 g = gasleft();
        if (g < GAS_RESERVE + MIN_LEG_GAS) return (LegStatus.SKIP_GAS, p);
        bytes memory data = abi.encodeCall(
            ConfluenceSplitter.planExactIn,
            (key, params.zeroForOne, params.sqrtPriceLimitX96, amount, a.snapTick, a.emaTickX)
        );
        bytes memory ret = new bytes(PLAN_BYTES);
        address target = address(splitter);
        uint256 gasCap = Math.min(g - GAS_RESERVE, PLAN_GAS_CAP);
        uint256 len = PLAN_BYTES;
        bool ok;
        assembly ("memory-safe") {
            // Nothing is copied unless the return is exactly `len` bytes long.
            ok := staticcall(gasCap, target, add(data, 0x20), mload(data), 0, 0)
            ok := and(ok, eq(returndatasize(), len))
            if ok { returndatacopy(add(ret, 0x20), 0, len) }
        }
        if (!ok) return (LegStatus.SKIP_PLAN, p);
        // Exactly PLAN_BYTES of static words: this decode cannot revert.
        p = abi.decode(ret, (Plan));
        address tokenIn = Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1);
        if (!_checkPlan(p, tokenIn, amount, n)) return (LegStatus.SKIP_PLAN, p);
        return (LegStatus.FILLED, p);
    }

    /// @dev The hook's own checks on a plan (D-35): valid codes; each leg for a registered slot, within the maker's
    /// [capMin, capIn] as read and at least `MIN_LEG_BPS`; at most `MAX_LEGS`; the legs and the pool's share sum to the
    /// amount; the legs' total within the PoolManager's balance of the input token (read here); outputs within int128;
    /// no pool share past a truncated walk; and the split's quoted output at least pool-only's plus the tail bound.
    /// Every operation is bounded so that no plan can make it revert.
    function _checkPlan(Plan memory p, address tokenIn, uint256 amount, uint256 n) private view returns (bool) {
        uint256 sumIn = 0;
        uint256 sumOut = 0;
        uint256 count = 0;
        for (uint256 i; i < MakerVenue.MAX_MAKERS; i++) {
            uint256 x = p.amountIn[i];
            if (i < n && p.status[i] > LegStatus.MAX_CODE) return false;
            if (x == 0) continue;
            if (i >= n || x > amount || x < p.capMin[i] || x > p.capIn[i]) return false;
            if (x * _BPS < amount * MIN_LEG_BPS || p.amountOut[i] > _MAX_INT128) return false;
            count++;
            sumIn += x;
            sumOut += p.amountOut[i];
        }
        if (count == 0) return true;
        if (count > MAX_LEGS || sumIn > amount || p.poolIn != amount - sumIn || sumOut > _MAX_INT128) return false;
        // forge-lint: disable-next-line(calls-loop)
        if (sumIn > IERC20(tokenIn).balanceOf(address(poolManager))) return false;
        if (p.poolOut > _MAX_INT128 || p.poolOnlyOut > _MAX_INT128 || p.tail > _MAX_INT128) return false;
        if (p.truncated != 0 && p.poolIn > p.walked) return false;
        return p.poolOut + sumOut >= p.poolOnlyOut + p.tail;
    }

    /// @dev Runs the planned legs. Takes their total input once, fills each through the router, then settles back
    /// what did not fill and settles the output received. `legs` holds one entry per slot with the plan's codes.
    function _legs(PoolKey calldata key, bool zeroForOne, Slot[] storage slots, Plan memory p, Leg[] memory legs)
        private
        returns (uint256 sumIn, uint256 sumOut)
    {
        (Currency cIn, Currency cOut) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        uint256 n = legs.length;
        uint256 planned = 0;
        for (uint256 i; i < n; i++) {
            planned += p.amountIn[i];
        }
        if (planned == 0) return (0, 0);
        if (gasleft() < GAS_RESERVE + MIN_LEG_GAS) {
            for (uint256 i; i < n; i++) {
                if (p.amountIn[i] > 0) legs[i].status = LegStatus.SKIP_GAS;
            }
            return (0, 0);
        }
        IERC20 tokenOut = IERC20(Currency.unwrap(cOut));
        cIn.take(poolManager, address(this), planned, false);
        uint256 outBefore = tokenOut.balanceOf(address(this));
        for (uint256 i; i < n; i++) {
            uint256 x = p.amountIn[i];
            if (x == 0) continue;
            (uint8 status, uint256 out) = _fill(key, slots[i], cIn, cOut, x, p.amountOut[i]);
            legs[i].status = status;
            if (status == LegStatus.FILLED) {
                (legs[i].amountIn, legs[i].amountOut) = (x, out);
                sumIn += x;
            }
        }
        // The output actually received: a router failure moves nothing, a fill moves exactly its output.
        sumOut = tokenOut.balanceOf(address(this)) - outBefore;
        if (planned > sumIn) cIn.settle(poolManager, address(this), planned - sumIn, false);
        if (sumOut > 0) cOut.settle(poolManager, address(this), sumOut, false);
    }

    /// @dev One leg: the order rebuilt from the slot (its hash must still be the registered one), `GAS_RESERVE` kept
    /// back, exact approval, the router call inside try/catch with a strict threshold of the planned output, approval
    /// reset to 0. The revert data is not copied (zero of the 256 bytes the spec allows).
    function _fill(PoolKey calldata key, Slot storage s, Currency cIn, Currency cOut, uint256 x, uint256 out)
        private
        returns (uint8 status, uint256 got)
    {
        ISwapVM.Order memory o = StrategyTemplate.order(
            s.maker, StrategyTemplate.program(s.params, poolManager, key, address(bandGuard))
        );
        if (StrategyTemplate.strategyHash(o) != s.strategyHash) return (LegStatus.SKIP_UNDERFUNDED, 0);
        uint256 g = gasleft();
        if (g < GAS_RESERVE + MIN_LEG_GAS) return (LegStatus.SKIP_GAS, 0);
        IERC20 tokenIn = IERC20(Currency.unwrap(cIn));
        tokenIn.forceApprove(ROUTER, x);
        status = LegStatus.SKIP_REVERT;
        // forge-lint: disable-start(calls-loop)
        try ISwapVM(ROUTER).swap{gas: Math.min(g - GAS_RESERVE, LEG_GAS_CAP)}(
            o, Currency.unwrap(cIn), Currency.unwrap(cOut), x, _takerData(out)
        ) returns (
            uint256, uint256 amountOut, bytes32
        ) {
            (status, got) = (LegStatus.FILLED, amountOut);
        } catch {}
        // forge-lint: disable-end(calls-loop)
        tokenIn.forceApprove(ROUTER, 0);
    }

    /// @dev Exact input, strict threshold `out` (the fill must give exactly the planned output), the input pulled from
    /// this hook and pushed to the maker through Aqua, the output to this hook, no deadline, hooks or callbacks.
    /// This is `TakerTraitsLib.build` for those arguments (`TakerTraits.sol:105-160`), written out to save code size
    /// (D-35): the ten slice indexes all end at the 32-byte threshold, then the flags, then the threshold. V2-07's
    /// mocked-router tests match the hook's calldata against `TakerTraitsLib.build` byte for byte.
    function _takerData(uint256 out) private pure returns (bytes memory) {
        return abi.encodePacked(_TAKER_SLICES, _TAKER_FLAGS, out);
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
