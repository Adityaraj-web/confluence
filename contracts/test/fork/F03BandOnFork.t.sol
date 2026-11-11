// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {Extruction} from "@1inch/swap-vm/src/instructions/Extruction.sol";
import {Fee, FeeArgsBuilder, BPS} from "@1inch/swap-vm/src/instructions/Fee.sol";
import {XYCSwap} from "@1inch/swap-vm/src/instructions/XYCSwap.sol";
import {Program, ProgramBuilder} from "@1inch/swap-vm/test/utils/ProgramBuilder.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {PoolPriceBandExtruction} from "../../src/v1/PoolPriceBandExtruction.sol";
import {ForkBase} from "../base/ForkBase.t.sol";
import {StrategyLib} from "../base/StrategyLib.sol";
import {TakerHelper} from "../base/TakerHelper.sol";

/// @notice F03: the band runs as an Extruction step on the canonical router against a real v4 pool's price.
/// @dev The band reads `slot0` and nothing else, so "the pool price moved 5%" is set up as a pool initialised 5% away
///      from Priya's curve. Moving a pool by swapping needs a seed position, which is F04.
contract F03BandOnForkTest is ForkBase, StrategyLib {
    using ProgramBuilder for Program;
    using StateLibrary for IPoolManager;

    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant SHIPPED_MUMB = 100_000e18;
    uint256 internal constant SHIPPED_USDC = 100_000e6;
    uint256 internal constant SWAP_USDC = 1_000e6;
    uint256 internal constant SWAP_MUMB = 1_000e18;
    uint16 internal constant BAND_BPS = 200;

    /// @dev Fees only keep the two pools a test may need apart.
    uint24 internal constant ANCHOR_POOL_FEE = 3000;
    uint24 internal constant MOVED_POOL_FEE = 500;

    /// @dev F02's measured fill for 1,000 USDC on these balances: the band must not change it.
    uint256 internal constant EXPECTED_MUMB_OUT = 987158034397061298850;

    IAqua internal aqua = IAqua(AQUA);
    IPoolManager internal manager = IPoolManager(POOL_MANAGER);

    PoolPriceBandExtruction internal band;
    TakerHelper internal helper;

    constructor() StrategyLib(AQUA) {}

    function setUp() public override {
        super.setUp();

        band = new PoolPriceBandExtruction();
        helper = new TakerHelper(ISwapVM(ROUTER));

        vm.startPrank(priya);
        mumb.approve(AQUA, type(uint256).max);
        IERC20(USDC).approve(AQUA, type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- helpers

    function _poolKey(uint24 fee) internal view returns (PoolKey memory) {
        (address currency0, address currency1) = sortedPair();
        return PoolKey(Currency.wrap(currency0), Currency.wrap(currency1), fee, 60, IHooks(address(0)));
    }

    /// @dev Pool price equal to Priya's curve spot: 1 whole USDC per 1 whole MUMB, in raw units.
    function _anchorSqrtPrice() internal view returns (uint160) {
        (address currency0,) = sortedPair();
        return currency0 == USDC ? uint160(1e6 * Q96) : uint160(Q96 / 1e6);
    }

    /// @dev The anchor price multiplied by 1.05.
    function _movedSqrtPrice() internal view returns (uint160) {
        return uint160(FullMath.mulDiv(_anchorSqrtPrice(), Math.sqrt(10_500e18), Math.sqrt(10_000e18)));
    }

    function _anchorPool() internal returns (PoolKey memory key) {
        key = _poolKey(ANCHOR_POOL_FEE);
        manager.initialize(key, _anchorSqrtPrice());
    }

    function _movedPool() internal returns (PoolKey memory key) {
        key = _poolKey(MOVED_POOL_FEE);
        manager.initialize(key, _movedSqrtPrice());
    }

    function _ship(bytes memory program) internal returns (ISwapVM.Order memory order, bytes32 strategyHash) {
        order = _buildOrder(priya, program);

        address[] memory tokens = new address[](2);
        tokens[0] = address(mumb);
        tokens[1] = USDC;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SHIPPED_MUMB;
        amounts[1] = SHIPPED_USDC;

        vm.prank(priya);
        strategyHash = aqua.ship(ROUTER, abi.encode(order), tokens, amounts);
    }

    function _shipBand(PoolKey memory key) internal returns (ISwapVM.Order memory order, bytes32 strategyHash) {
        bytes memory args = band.build(manager, key, BAND_BPS);
        return _ship(_buildBandProgram(FEE_0_30_PCT, address(band), args));
    }

    function _netOfFee(uint256 amountIn) internal pure returns (uint256) {
        return amountIn - Math.ceilDiv(amountIn * FEE_0_30_PCT, BPS);
    }

    function _shippedBalance(address token) internal view returns (uint256) {
        return token == USDC ? SHIPPED_USDC : (token == address(mumb) ? SHIPPED_MUMB : 0);
    }

    /// @dev Fee (rounded up, on input) then XYC (rounded down) on the shipped balances.
    function _expectedOut(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        uint256 net = _netOfFee(amountIn);
        return (net * _shippedBalance(tokenOut)) / (_shippedBalance(tokenIn) + net);
    }

    /// @dev The price the band sees: net-of-fee input (D-15), oriented as currency1 per currency0.
    function _expectedExecX96(address tokenIn, uint256 amountIn, uint256 amountOut) internal view returns (uint256) {
        (address currency0,) = sortedPair();
        uint256 net = _netOfFee(amountIn);
        return tokenIn == currency0 ? FullMath.mulDiv(amountOut, Q96, net) : FullMath.mulDiv(net, Q96, amountOut);
    }

    function _poolX96(PoolKey memory key) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        return FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
    }

    /// @dev Encoded `PoolPriceBandExceeded` for this fill against this pool.
    function _exceededError(PoolKey memory key, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            PoolPriceBandExtruction.PoolPriceBandExceeded.selector,
            _expectedExecX96(tokenIn, amountIn, _expectedOut(tokenIn, tokenOut, amountIn)),
            _poolX96(key),
            BAND_BPS
        );
    }

    /// @dev Fills through the router and asserts the amounts, the recipient and that the taker keeps nothing.
    function _fillAndCheck(ISwapVM.Order memory order, address tokenIn, address tokenOut, uint256 amountIn) internal {
        uint256 expectedOut = _expectedOut(tokenIn, tokenOut, amountIn);
        uint256 traderOutBefore = IERC20(tokenOut).balanceOf(trader);
        deal(tokenIn, address(helper), amountIn);

        (uint256 swappedIn, uint256 swappedOut,) =
            helper.swapExactIn(order, tokenIn, tokenOut, amountIn, expectedOut, trader);

        assertEq(swappedIn, amountIn, "amountIn");
        assertEq(swappedOut, expectedOut, "amountOut");
        assertGt(swappedOut, 0, "amountOut is zero");
        assertEq(IERC20(tokenOut).balanceOf(trader), traderOutBefore + expectedOut, "trader output");
        _assertHoldsNothing(address(helper), "helper");
    }

    function _assertHoldsNothing(address who, string memory name) internal view {
        (uint256 mumbBal, uint256 usdcBal) = balances(who);
        assertEq(mumbBal, 0, string.concat(name, " MUMB"));
        assertEq(usdcBal, 0, string.concat(name, " USDC"));
    }

    // ---------------------------------------------------------------- acceptance

    function test_F03_inBandFills() public {
        (ISwapVM.Order memory order, bytes32 strategyHash) = _shipBand(_anchorPool());
        deal(USDC, address(helper), SWAP_USDC);

        uint256 managerUsdcBefore = IERC20(USDC).balanceOf(POOL_MANAGER);

        (uint256 swappedIn, uint256 swappedOut,) =
            helper.swapExactIn(order, USDC, address(mumb), SWAP_USDC, EXPECTED_MUMB_OUT, trader);

        assertEq(swappedIn, SWAP_USDC, "amountIn");
        assertEq(swappedOut, EXPECTED_MUMB_OUT, "amountOut");

        (uint256 walletMumb, uint256 walletUsdc) = balances(priya);
        assertEq(walletMumb, PRIYA_MUMB - EXPECTED_MUMB_OUT, "Priya wallet MUMB");
        assertEq(walletUsdc, PRIYA_USDC + SWAP_USDC, "Priya wallet USDC");

        (uint256 virtualMumb, uint256 virtualUsdc) =
            aqua.safeBalances(priya, ROUTER, strategyHash, address(mumb), USDC);
        assertEq(virtualMumb, SHIPPED_MUMB - EXPECTED_MUMB_OUT, "virtual MUMB");
        assertEq(virtualUsdc, SHIPPED_USDC + SWAP_USDC, "virtual USDC");

        (uint256 traderMumb, uint256 traderUsdc) = balances(trader);
        assertEq(traderMumb, TRADER_MUMB + EXPECTED_MUMB_OUT, "trader MUMB");
        assertEq(traderUsdc, TRADER_USDC, "trader USDC");

        _assertHoldsNothing(address(helper), "helper");
        _assertHoldsNothing(address(band), "band");

        // The fill never touches the pool.
        assertEq(mumb.balanceOf(POOL_MANAGER), 0, "PoolManager MUMB");
        assertEq(IERC20(USDC).balanceOf(POOL_MANAGER), managerUsdcBefore, "PoolManager USDC");
    }

    function test_F03_outOfBandReverts() public {
        PoolKey memory key = _movedPool();
        (ISwapVM.Order memory order, bytes32 strategyHash) = _shipBand(key);
        deal(USDC, address(helper), SWAP_USDC);

        vm.expectRevert(_exceededError(key, USDC, address(mumb), SWAP_USDC));
        helper.swapExactIn(order, USDC, address(mumb), SWAP_USDC, 0, trader);

        // Nothing moved: the band runs before any transfer.
        (uint256 helperMumb, uint256 helperUsdc) = balances(address(helper));
        assertEq(helperMumb, 0, "helper MUMB");
        assertEq(helperUsdc, SWAP_USDC, "helper USDC");

        (uint256 walletMumb, uint256 walletUsdc) = balances(priya);
        assertEq(walletMumb, PRIYA_MUMB, "Priya wallet MUMB");
        assertEq(walletUsdc, PRIYA_USDC, "Priya wallet USDC");

        (uint256 virtualMumb, uint256 virtualUsdc) =
            aqua.safeBalances(priya, ROUTER, strategyHash, address(mumb), USDC);
        assertEq(virtualMumb, SHIPPED_MUMB, "virtual MUMB");
        assertEq(virtualUsdc, SHIPPED_USDC, "virtual USDC");
    }

    function test_F03_quoteRevertsOutOfBand() public {
        PoolKey memory key = _movedPool();
        (ISwapVM.Order memory order,) = _shipBand(key);

        vm.expectRevert(_exceededError(key, USDC, address(mumb), SWAP_USDC));
        helper.quoteExactIn(order, USDC, address(mumb), SWAP_USDC, 0);
    }

    function test_F03_bothDirections() public {
        (ISwapVM.Order memory anchored,) = _shipBand(_anchorPool());
        PoolKey memory movedKey = _movedPool();
        (ISwapVM.Order memory moved,) = _shipBand(movedKey);

        // In band, each direction from the same starting state.
        uint256 snapshot = vm.snapshotState();
        _fillAndCheck(anchored, USDC, address(mumb), SWAP_USDC);
        vm.revertToState(snapshot);
        _fillAndCheck(anchored, address(mumb), USDC, SWAP_MUMB);
        vm.revertToState(snapshot);

        // Out of band, each direction, on both quote and swap.
        deal(USDC, address(helper), SWAP_USDC);
        vm.expectRevert(_exceededError(movedKey, USDC, address(mumb), SWAP_USDC));
        helper.swapExactIn(moved, USDC, address(mumb), SWAP_USDC, 0, trader);
        vm.expectRevert(_exceededError(movedKey, USDC, address(mumb), SWAP_USDC));
        helper.quoteExactIn(moved, USDC, address(mumb), SWAP_USDC, 0);

        deal(address(mumb), address(helper), SWAP_MUMB);
        vm.expectRevert(_exceededError(movedKey, address(mumb), USDC, SWAP_MUMB));
        helper.swapExactIn(moved, address(mumb), USDC, SWAP_MUMB, 0, trader);
        vm.expectRevert(_exceededError(movedKey, address(mumb), USDC, SWAP_MUMB));
        helper.quoteExactIn(moved, address(mumb), USDC, SWAP_MUMB, 0);
    }

    function test_F03_quoteEqualsSwapSameTx() public {
        (ISwapVM.Order memory order, bytes32 strategyHash) = _shipBand(_anchorPool());
        deal(USDC, address(helper), SWAP_USDC);

        (uint256 quotedIn, uint256 quotedOut, bytes32 quotedHash) =
            helper.quoteExactIn(order, USDC, address(mumb), SWAP_USDC, 0);
        (uint256 swappedIn, uint256 swappedOut, bytes32 swappedHash) =
            helper.swapExactIn(order, USDC, address(mumb), SWAP_USDC, 0, trader);

        assertEq(quotedIn, swappedIn, "amountIn");
        assertEq(quotedOut, swappedOut, "amountOut");
        assertEq(quotedHash, swappedHash, "orderHash");
        assertEq(quotedHash, strategyHash, "orderHash != strategy hash");
        assertEq(swappedOut, EXPECTED_MUMB_OUT, "amountOut value");
    }

    function test_F03_wrongPoolTokensReverts() public {
        // A WETH/USDC key while the swap is MUMB/USDC. The pool need not exist: the token check comes first.
        PoolKey memory wrongKey =
            PoolKey(Currency.wrap(USDC), Currency.wrap(WETH), ANCHOR_POOL_FEE, 60, IHooks(address(0)));
        (ISwapVM.Order memory order,) = _shipBand(wrongKey);
        deal(USDC, address(helper), SWAP_USDC);

        vm.expectRevert(PoolPriceBandExtruction.PoolTokenMismatch.selector);
        helper.swapExactIn(order, USDC, address(mumb), SWAP_USDC, 0, trader);

        vm.expectRevert(PoolPriceBandExtruction.PoolTokenMismatch.selector);
        helper.quoteExactIn(order, USDC, address(mumb), SWAP_USDC, 0);
    }

    function test_F03_misorderedProgramReverts() public {
        // Extruction before the curve, so `amountOut` is still zero when it runs.
        bytes memory args = band.build(manager, _anchorPool(), BAND_BPS);
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory program = bytes.concat(
            p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(FEE_0_30_PCT)),
            p.build(Extruction._extruction, abi.encodePacked(address(band), args)),
            p.build(XYCSwap._xycSwapXD)
        );
        (ISwapVM.Order memory order,) = _ship(program);

        // Both directions: one divides by amountIn and the other by amountOut, so neither may reach the division.
        deal(USDC, address(helper), SWAP_USDC);
        vm.expectRevert(PoolPriceBandExtruction.PoolPriceBandNotComputed.selector);
        helper.swapExactIn(order, USDC, address(mumb), SWAP_USDC, 0, trader);
        vm.expectRevert(PoolPriceBandExtruction.PoolPriceBandNotComputed.selector);
        helper.quoteExactIn(order, USDC, address(mumb), SWAP_USDC, 0);

        deal(address(mumb), address(helper), SWAP_MUMB);
        vm.expectRevert(PoolPriceBandExtruction.PoolPriceBandNotComputed.selector);
        helper.swapExactIn(order, address(mumb), USDC, SWAP_MUMB, 0, trader);
        vm.expectRevert(PoolPriceBandExtruction.PoolPriceBandNotComputed.selector);
        helper.quoteExactIn(order, address(mumb), USDC, SWAP_MUMB, 0);
    }

    function test_F03_noStorage() public {
        (ISwapVM.Order memory order,) = _shipBand(_anchorPool());
        deal(USDC, address(helper), SWAP_USDC);

        vm.record();
        (, uint256 swappedOut,) = helper.swapExactIn(order, USDC, address(mumb), SWAP_USDC, 0, trader);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(band));

        // The swap filled. That it ran through the band at all is what `test_F03_outOfBandReverts` proves.
        assertEq(swappedOut, EXPECTED_MUMB_OUT, "amountOut");
        assertEq(writes.length, 0, "band wrote storage");
        assertEq(reads.length, 0, "band read storage");
    }
}
