// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {ConfluenceHookV1 as ConfluenceHook} from "../../src/v1/ConfluenceHookV1.sol";
import {ForkBase} from "./ForkBase.t.sol";

/// @notice Pool setup for F04 and later: the hook at a mined address, the MUMB/USDC pool at the anchor
/// price, a seed position, and the v4-core test routers (neither exists on mainnet).
abstract contract PoolBase is ForkBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    /// @dev Seed range is the anchor tick rounded to the spacing, plus and minus this many ticks (about 6%).
    int24 internal constant HALF_RANGE = 600;
    uint256 internal constant SEED_USDC = 2_500e6;
    uint256 internal constant SEED_MUMB = 2_500e18;

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    ConfluenceHook internal hook;

    PoolKey internal key;
    PoolId internal poolId;
    /// @dev True when USDC is currency0 (address(USDC) < address(mumb)).
    bool internal usdcIsCurrency0;
    int24 internal tickLower;
    int24 internal tickUpper;

    function setUp() public virtual override {
        super.setUp();

        manager = IPoolManager(POOL_MANAGER);
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        usdcIsCurrency0 = USDC < address(mumb);

        _deployHook();
        key = _createPool(IHooks(address(hook)));
        poolId = key.toId();
    }

    // ---------------------------------------------------------------- setup

    /// @dev Mines a CREATE2 salt for exactly beforeSwap + beforeSwapReturnDelta, then deploys from this contract.
    function _deployHook() internal {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(manager, ROUTER);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ConfluenceHook).creationCode, args);
        hook = new ConfluenceHook{salt: salt}(manager, ROUTER);
        require(address(hook) == expected, "PoolBase: hook address mismatch");
    }

    /// @dev Initialises a MUMB/USDC pool (fee 3000, spacing 60) at the anchor price and adds the seed position
    /// from the deployer. `hooks` may be address(0) for a hook-less comparison pool.
    function _createPool(IHooks hooks) internal returns (PoolKey memory k) {
        (address c0, address c1) = sortedPair();
        k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: hooks
        });

        uint160 sqrtPriceX96 = anchorSqrtPriceX96(usdcIsCurrency0);
        int24 tick = manager.initialize(k, sqrtPriceX96);

        int24 centre = _floorToSpacing(tick);
        tickLower = centre - HALF_RANGE;
        tickUpper = centre + HALF_RANGE;

        // Seed from the deployer: about 2,500 of each token, about 5,000 USDC of value.
        vm.startPrank(deployer);
        mumb.mint(deployer, SEED_MUMB);
        vm.stopPrank();
        deal(USDC, deployer, SEED_USDC);

        uint256 amount0 = usdcIsCurrency0 ? SEED_USDC : SEED_MUMB;
        uint256 amount1 = usdcIsCurrency0 ? SEED_MUMB : SEED_USDC;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        vm.startPrank(deployer);
        IERC20(USDC).approve(address(liquidityRouter), type(uint256).max);
        mumb.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- price maths

    /// @notice sqrtPriceX96 for 1 MUMB = 1 USDC given the currency order.
    /// @dev v4 price is raw currency1 per raw currency0. MUMB has 18 decimals and USDC 6, so:
    /// USDC is currency0: price = 1e18 / 1e6 = 1e12, sqrt = 1e6, sqrtPriceX96 = 1e6 * 2^96.
    /// MUMB is currency0: price = 1e6 / 1e18 = 1e-12, sqrt = 1e-6, sqrtPriceX96 = 2^96 / 1e6.
    /// Both are exact square roots, so there is no rounding in the choice of 1e6.
    function anchorSqrtPriceX96(bool usdcIsC0) internal pure returns (uint160) {
        return usdcIsC0 ? uint160(FixedPoint96.Q96 * 1e6) : uint160(FixedPoint96.Q96 / 1e6);
    }

    function _floorToSpacing(int24 tick) internal pure returns (int24 c) {
        c = (tick / TICK_SPACING) * TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) c -= TICK_SPACING;
    }

    // ---------------------------------------------------------------- swap helpers

    /// @dev Direction flag for "pay USDC, receive MUMB".
    function usdcForMumb() internal view returns (bool zeroForOne) {
        return usdcIsCurrency0;
    }

    function _swap(PoolKey memory k, address who, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta delta)
    {
        vm.startPrank(who);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        mumb.approve(address(swapRouter), type(uint256).max);
        delta = swapRouter.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        vm.stopPrank();
    }

    /// @dev Exact-input swap on the main pool.
    function _swapExactIn(address who, bool zeroForOne, uint256 amountIn, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        return _swap(key, who, zeroForOne, -int256(amountIn), hookData);
    }

    /// @dev Exact-output swap on the main pool.
    function _swapExactOut(address who, bool zeroForOne, uint256 amountOut, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        return _swap(key, who, zeroForOne, int256(amountOut), hookData);
    }

    /// @dev The signed MUMB amount of a swap delta, whatever the currency order.
    function mumbAmount(BalanceDelta d) internal view returns (int128) {
        return usdcIsCurrency0 ? d.amount1() : d.amount0();
    }

    /// @dev The signed USDC amount of a swap delta, whatever the currency order.
    function usdcAmount(BalanceDelta d) internal view returns (int128) {
        return usdcIsCurrency0 ? d.amount0() : d.amount1();
    }

    function _assertHookHoldsNothing() internal view {
        assertEq(mumb.balanceOf(address(hook)), 0, "hook holds MUMB");
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "hook holds USDC");
        assertEq(address(hook).balance, 0, "hook holds ETH");
    }
}
