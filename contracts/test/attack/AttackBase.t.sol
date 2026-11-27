// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {StrategyTemplate} from "../../src/libraries/StrategyTemplate.sol";
import {SplitBase} from "../base/SplitBase.t.sol";

/// @notice A test ERC-20 whose behaviour is switched after the pool is set up (V2-10, hostile tokens). Own
///         implementation, 18 decimals, anyone may mint. Switches: a fee burned on every transfer, no return value,
///         `false` return, a revert on `approve(0)`, a blocklist, and one call-out to `target` at the n-th
///         qualifying `transfer`/`transferFrom` (a re-entry probe).
contract HostileToken {
    string public constant name = "Hostile";
    string public constant symbol = "HOST";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public feeBps; // burned from the received amount
    bool public noReturn;
    bool public returnFalse;
    bool public revertApproveZero;
    mapping(address => bool) public blocked;

    address public target; // call-out; zero = off
    bytes public data;
    uint8 public fireMask; // bit0 transfer, bit1 transferFrom, bit2 approve (before), bit3 approve (after the allowance is set)
    uint256 public fireAt; // 1-based count of qualifying calls since arming
    uint256 public calls; // qualifying calls since arming
    bool public fired;
    bool public lastOk;
    bytes public lastRet;
    bool private _inside;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setFeeBps(uint256 v) external {
        feeBps = v;
    }

    function setNoReturn(bool v) external {
        noReturn = v;
    }

    function setReturnFalse(bool v) external {
        returnFalse = v;
    }

    function setRevertApproveZero(bool v) external {
        revertApproveZero = v;
    }

    function setBlocked(address a, bool v) external {
        blocked[a] = v;
    }

    /// @dev Arm the call-out: at the `at`-th qualifying call (mask bits as `fireMask`), `target.call(payload)`.
    function arm(address t, bytes calldata payload, uint8 mask, uint256 at) external {
        (target, data, fireMask, fireAt, calls, fired) = (t, payload, mask, at, 0, false);
    }

    function disarm() external {
        target = address(0);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (revertApproveZero && amount == 0) revert("approve zero");
        _probe(4);
        allowance[msg.sender][spender] = amount;
        _probe(8);
        return _ret(true);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _probe(1);
        if (returnFalse) return false;
        _move(msg.sender, to, amount);
        return _ret(true);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _probe(2);
        if (returnFalse) return false;
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "allowance");
            allowance[from][msg.sender] = a - amount;
        }
        _move(from, to, amount);
        return _ret(true);
    }

    function _move(address from, address to, uint256 amount) private {
        require(!blocked[from] && !blocked[to], "blocked");
        balanceOf[from] -= amount;
        uint256 fee = amount * feeBps / 10_000;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
    }

    function _ret(bool v) private view returns (bool) {
        if (noReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return v;
    }

    function _probe(uint8 kind) private {
        if (target == address(0) || _inside || fireMask & kind == 0) return;
        if (++calls != fireAt) return;
        _inside = true;
        (lastOk, lastRet) = target.call(data);
        fired = true;
        _inside = false;
    }
}

/// @notice A trader's router that pays with SafeERC20, so it can swap tokens that return nothing (v4-core's
///         `PoolSwapTest` settles through `IERC20Minimal`, whose `bool` return a no-return token cannot satisfy).
contract SafeSwapRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    error NotManager();

    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    /// @notice Swap, paying and receiving through the caller. Anyone may call (it moves only the caller's tokens).
    function swap(PoolKey calldata key, IPoolManager.SwapParams calldata p) external returns (BalanceDelta d) {
        d = abi.decode(manager.unlock(abi.encode(msg.sender, key, p)), (BalanceDelta));
    }

    /// @notice Called by the PoolManager only.
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        (address payer, PoolKey memory key, IPoolManager.SwapParams memory p) =
            abi.decode(raw, (address, PoolKey, IPoolManager.SwapParams));
        BalanceDelta d = manager.swap(key, p, "");
        _settle(key.currency0, payer, d.amount0());
        _settle(key.currency1, payer, d.amount1());
        return abi.encode(d);
    }

    function _settle(Currency c, address payer, int128 amt) private {
        if (amt < 0) {
            manager.sync(c);
            // casting to 'uint128' is safe: amt is negative, so -amt is positive and fits
            // forge-lint: disable-next-line(unsafe-typecast)
            IERC20(Currency.unwrap(c)).safeTransferFrom(payer, address(manager), uint128(-amt));
            manager.settle();
        } else if (amt > 0) {
            // casting to 'uint128' is safe: amt is positive
            // forge-lint: disable-next-line(unsafe-typecast)
            manager.take(c, payer, uint128(amt));
        }
    }
}

/// @notice Shared V2-10 fixture: PnL, the after-attack books, a hostile-token pool and makers on it.
abstract contract AttackBase is SplitBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SafeSwapRouter internal safeRouter;
    HostileToken internal host;
    PoolKey internal hostKey;
    address internal attacker;

    /// @dev `SplitBase.setUp` is not virtual, so tests call this first (after `setUp` has run).
    function _attackInit() internal {
        safeRouter = new SafeSwapRouter(manager);
        attacker = makeAddr("attacker");
    }

    // =====================================================================================================
    // After every attack
    // =====================================================================================================

    /// @dev The hook holds nothing, every allowance it or the router could leave is 0. (Deltas net: a swap that
    ///      returned proves `unlock` found none open, `PoolManager.sol:111`.)
    function _assertAfterAttack(address tokenB) internal view {
        assertEq(IERC20(USDC).balanceOf(address(hookV2)), 0, "hook USDC");
        assertEq(IERC20(tokenB).balanceOf(address(hookV2)), 0, "hook token");
        assertEq(address(hookV2).balance, 0, "hook ETH");
        assertEq(IERC20(USDC).allowance(address(hookV2), ROUTER), 0, "hook -> router USDC");
        assertEq(IERC20(tokenB).allowance(address(hookV2), ROUTER), 0, "hook -> router token");
        assertEq(IERC20(USDC).allowance(ROUTER, AQUA), 0, "router -> Aqua USDC");
        assertEq(IERC20(tokenB).allowance(ROUTER, AQUA), 0, "router -> Aqua token");
    }

    // =====================================================================================================
    // PnL (raw USDC units, the token valued at 1 USDC, the pool's anchor price: 1e12 raw per raw USDC)
    // =====================================================================================================

    function _value(address who, address tokenB) internal view returns (int256) {
        return int256(IERC20(USDC).balanceOf(who)) + int256(IERC20(tokenB).balanceOf(who) / 1e12);
    }

    function _logPnl(string memory label, address who, address tokenB, int256 before_) internal {
        emit log_named_int(string.concat(label, " PnL (raw USDC)"), _value(who, tokenB) - before_);
    }

    // =====================================================================================================
    // A hostile-token pool: (HostileToken, USDC) on the v2 hook, behaviour switched on after setup
    // =====================================================================================================

    /// @dev Deploys the token, initialises the pool at 1 token = 1 USDC, seeds ~2,500 of each around the price
    ///      (the same shape as the main pool), records the anchor, funds and approves the trader. The token is
    ///      benign until a test switches it.
    function _hostilePool() internal returns (PoolKey memory k) {
        if (address(safeRouter) == address(0)) _attackInit();
        host = new HostileToken();
        host.mint(trader, 100_000e18);
        host.mint(attacker, 100_000e18);
        deal(USDC, attacker, 1_000_000e6);
        for (uint256 i; i < 2; i++) {
            vm.startPrank(i == 0 ? trader : attacker);
            IERC20(USDC).approve(address(safeRouter), type(uint256).max);
            host.approve(address(safeRouter), type(uint256).max);
            vm.stopPrank();
        }
        return _hostilePoolOn(POOL_FEE, TICK_SPACING);
    }

    /// @dev Another hooked pool on the same hostile token (a different fee or spacing gives a different pool id).
    function _hostilePoolOn(uint24 fee, int24 spacing) internal returns (PoolKey memory k) {
        bool usdc0 = USDC < address(host);
        (address c0, address c1) = usdc0 ? (USDC, address(host)) : (address(host), USDC);
        k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(address(hookV2))
        });
        uint160 sp = anchorSqrtPriceX96(usdc0);
        int24 tick = manager.initialize(k, sp);
        int24 lo = (tick / spacing) * spacing - 600;
        int24 hi = (tick / spacing) * spacing + 600;
        host.mint(deployer, SEED_MUMB);
        deal(USDC, deployer, SEED_USDC);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sp,
            TickMath.getSqrtPriceAtTick(lo),
            TickMath.getSqrtPriceAtTick(hi),
            usdc0 ? SEED_USDC : SEED_MUMB,
            usdc0 ? SEED_MUMB : SEED_USDC
        );
        vm.startPrank(deployer);
        IERC20(USDC).approve(address(liquidityRouter), type(uint256).max);
        host.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lo, tickUpper: hi, liquidityDelta: int256(uint256(liq)), salt: bytes32(0)
            }),
            ""
        );
        vm.stopPrank();
        hostKey = k;
        // records the anchor (a 1 raw unit swap is eaten whole by the fee, so the price does not move)
        _hSwap(k, trader, usdc0, -1);
    }

    /// @dev A swap on a hostile-token pool through the SafeERC20 router.
    function _hSwap(PoolKey memory k, address who, bool zfo, int256 spec) internal returns (BalanceDelta d) {
        vm.prank(who);
        d = safeRouter.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: zfo,
                amountSpecified: spec,
                sqrtPriceLimitX96: zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    /// @dev Direction "pay USDC, receive the hostile token" on `k`.
    function _usdcIn(PoolKey memory k) internal pure returns (bool) {
        return Currency.unwrap(k.currency0) == USDC;
    }

    /// @dev Fund (wallet = virtual), ship and register a T1 maker on a hostile-token pool; amounts at price 1.
    function _joinHost(PoolKey memory k, address m, uint256 tokenAmt, uint256 usdcAmt, StrategyTemplate.Params memory p)
        internal
        returns (bytes32 h)
    {
        host.mint(m, tokenAmt);
        deal(USDC, m, IERC20(USDC).balanceOf(m) + usdcAmt);
        vm.startPrank(m);
        host.approve(AQUA, type(uint256).max);
        IERC20(USDC).approve(AQUA, type(uint256).max);
        vm.stopPrank();
        bool usdc0 = _usdcIn(k);
        address[] memory t = new address[](2);
        uint256[] memory a = new uint256[](2);
        (t[0], t[1]) = (Currency.unwrap(k.currency0), Currency.unwrap(k.currency1));
        (a[0], a[1]) = usdc0 ? (usdcAmt, tokenAmt) : (tokenAmt, usdcAmt);
        bytes memory prog = StrategyTemplate.program(p, manager, k, _guard());
        vm.prank(m);
        h = IAqua(AQUA).ship(ROUTER, abi.encode(StrategyTemplate.order(m, prog)), t, a);
        vm.prank(m);
        hookV2.register(k, p);
    }
}
