// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {MakerTraits} from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {PoolBase} from "../base/PoolBase.t.sol";

contract F04PoolSkeletonTest is PoolBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant TRADE_USDC = 1_000e6;

    function _order(address maker) internal pure returns (ISwapVM.Order memory) {
        return ISwapVM.Order({maker: maker, traits: MakerTraits.wrap(0), data: hex"c0ffee"});
    }

    // ---------------------------------------------------------------- acceptance

    function test_F04_hookPermissions() public view {
        uint160 expected = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, expected, "address flags");

        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap, "beforeSwap");
        assertTrue(p.beforeSwapReturnDelta, "beforeSwapReturnDelta");
        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    function test_F04_poolOnlySwap() public {
        (uint256 mumbBefore, uint256 usdcBefore) = balances(trader);

        BalanceDelta d = _swapExactIn(trader, usdcForMumb(), TRADE_USDC, "");

        (uint256 mumbAfter, uint256 usdcAfter) = balances(trader);
        assertEq(usdcBefore - usdcAfter, TRADE_USDC, "trader USDC spent");
        assertEq(int128(-int256(TRADE_USDC)), usdcAmount(d), "delta USDC");
        assertGt(mumbAfter - mumbBefore, 0, "trader got MUMB");
        assertEq(int256(mumbAfter - mumbBefore), int256(mumbAmount(d)), "trader MUMB equals swap delta");
        // 1,000 USDC at about 1 MUMB each, less the 0.30% fee and price impact on a thin seed.
        assertGt(mumbAfter - mumbBefore, 950e18, "output above 95% of par");
        assertLt(mumbAfter - mumbBefore, 1_000e18, "output below par");

        _assertHookHoldsNothing();

        // The swap stayed inside the seed range, so it was a real fill by the curve.
        (, int24 tick,,) = manager.getSlot0(poolId);
        assertGt(tick, tickLower, "tick above range floor");
        assertLt(tick, tickUpper, "tick below range ceiling");
    }

    function test_F04_registerOrderMakerOnly() public {
        ISwapVM.Order memory order = _order(priya);

        vm.prank(trader);
        vm.expectRevert(ConfluenceHook.NotMaker.selector);
        hook.registerOrder(key, order);

        vm.expectEmit(true, true, false, true, address(hook));
        emit ConfluenceHook.OrderRegistered(poolId, priya, keccak256(abi.encode(order)));
        vm.prank(priya);
        hook.registerOrder(key, order);

        ISwapVM.Order memory stored = hook.orderOf(poolId);
        assertEq(stored.maker, priya, "stored maker");
        assertEq(MakerTraits.unwrap(stored.traits), 0, "stored traits");
        assertEq(stored.data, order.data, "stored data");
    }

    function test_F04_exactOutputStillWorks() public {
        (uint256 mumbBefore, uint256 usdcBefore) = balances(trader);

        BalanceDelta d = _swapExactOut(trader, usdcForMumb(), 500e18, "");

        (uint256 mumbAfter, uint256 usdcAfter) = balances(trader);
        assertEq(mumbAfter - mumbBefore, 500e18, "trader MUMB received exactly");
        assertEq(int256(mumbAmount(d)), int256(500e18), "delta MUMB");
        uint256 spent = usdcBefore - usdcAfter;
        assertEq(int256(usdcAmount(d)), -int256(spent), "delta USDC");
        assertGt(spent, 500e6, "paid more than par");
        assertLt(spent, 520e6, "paid under 4% over par");

        _assertHookHoldsNothing();
    }

    // ---------------------------------------------------------------- extras

    function test_F04_unregisterOrderMakerOnly() public {
        vm.prank(priya);
        hook.registerOrder(key, _order(priya));

        vm.prank(trader);
        vm.expectRevert(ConfluenceHook.NotMaker.selector);
        hook.unregisterOrder(key);

        vm.expectEmit(true, true, false, false, address(hook));
        emit ConfluenceHook.OrderUnregistered(poolId, priya);
        vm.prank(priya);
        hook.unregisterOrder(key);

        assertEq(hook.orderOf(poolId).maker, address(0), "order cleared");
    }

    function test_F04_unregisterWithoutOrderReverts() public {
        vm.prank(priya);
        vm.expectRevert(ConfluenceHook.NoOrder.selector);
        hook.unregisterOrder(key);
    }

    function test_F04_beforeSwapOnlyPoolManager() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: usdcForMumb(),
            amountSpecified: -int256(TRADE_USDC),
            sqrtPriceLimitX96: usdcForMumb() ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        vm.expectRevert(ConfluenceHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
    }

    function test_F04_hookDataIgnored() public {
        uint256 snap = vm.snapshotState();
        BalanceDelta plain = _swapExactIn(trader, usdcForMumb(), TRADE_USDC, "");
        vm.revertToState(snap);

        BalanceDelta withData = _swapExactIn(trader, usdcForMumb(), TRADE_USDC, abi.encode(uint256(400e6)));

        assertEq(mumbAmount(withData), mumbAmount(plain), "hint ignored: same MUMB out");
        assertEq(usdcAmount(withData), usdcAmount(plain), "hint ignored: same USDC in");
        _assertHookHoldsNothing();
    }

    function test_F04_poolInitialisedAtAnchor() public view {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        assertEq(sqrtPriceX96, anchorSqrtPriceX96(usdcIsCurrency0), "slot0 price is the anchor");
        assertGt(manager.getLiquidity(poolId), 0, "seed liquidity");
        assertEq(tickLower % TICK_SPACING, 0, "lower tick on spacing");
        assertEq(tickUpper % TICK_SPACING, 0, "upper tick on spacing");
        assertEq(tickUpper - tickLower, 2 * HALF_RANGE, "range width");
    }

    /// @dev Both currency orders give 1 MUMB = 1 USDC, mirrored around tick 0.
    function test_F04_anchorPriceBothOrders() public pure {
        int24 tickUsdc0 = TickMath.getTickAtSqrtPrice(anchorSqrtPriceX96(true));
        int24 tickMumb0 = TickMath.getTickAtSqrtPrice(anchorSqrtPriceX96(false));
        // ln(1e12) / ln(1.0001) = 276,324.
        assertGt(tickUsdc0, 276_320, "USDC currency0 tick");
        assertLt(tickUsdc0, 276_330, "USDC currency0 tick");
        assertGt(tickMumb0, -276_330, "MUMB currency0 tick");
        assertLt(tickMumb0, -276_320, "MUMB currency0 tick");
    }

    /// @dev A zero-delta hook must not change pool maths: same swap on a hook-less twin pool gives the same fill.
    function test_F04_beforeSwapZeroDeltaSwapEqualsNoHookSwap() public {
        PoolKey memory plainKey = _createPool(IHooks(address(0)));

        uint256 snap = vm.snapshotState();
        BalanceDelta withHook = _swapExactIn(trader, usdcForMumb(), TRADE_USDC, "");
        vm.revertToState(snap);
        BalanceDelta without = _swap(plainKey, trader, usdcForMumb(), -int256(TRADE_USDC), "");

        assertEq(mumbAmount(withHook), mumbAmount(without), "same MUMB out");
        assertEq(usdcAmount(withHook), usdcAmount(without), "same USDC in");
    }
}
