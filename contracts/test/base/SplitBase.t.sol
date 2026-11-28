// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BandExceeded, TakerNotHook} from "../../src/BandGuardV2.sol";
import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {ConfluenceSplitter, IConfluenceHookView, LegStatus, Plan} from "../../src/ConfluenceSplitter.sol";
import {ConfluenceSplitterOut} from "../../src/ConfluenceSplitterOut.sol";
import {SplitMath} from "../../src/libraries/SplitMath.sol";
import {MakerVenue} from "../../src/libraries/MakerVenue.sol";
import {PoolVenue} from "../../src/libraries/PoolVenue.sol";
import {StrategyTemplate} from "../../src/libraries/StrategyTemplate.sol";
import {PoolPriceBandExtruction} from "../../src/v1/PoolPriceBandExtruction.sol";
import {RegistryBase} from "./RegistryBase.t.sol";
import {Vectors} from "./Vectors.sol";

/// @notice A trader's router with a slippage limit: an exact-input swap through v4-core's `PoolSwapTest` that reverts
///         when the output is under `minOut`, as V4Router's `amountOutMinimum` does (`V4Router.sol:93`; that router
///         pins solc 0.8.26 and does not build under this profile).
contract MinOutRouter {
    error TooLittleReceived(uint256 minOut, uint256 got);

    PoolSwapTest internal immutable router;

    constructor(PoolSwapTest r) {
        router = r;
    }

    /// @notice Pulls `amountIn` from the caller, swaps it, sends the output to the caller. Anyone may call.
    function swapExactIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minOut)
        external
        returns (uint256 got)
    {
        (Currency cIn, Currency cOut) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        IERC20 tIn = IERC20(Currency.unwrap(cIn));
        IERC20 tOut = IERC20(Currency.unwrap(cOut));
        require(tIn.transferFrom(msg.sender, address(this), amountIn), "pull");
        tIn.approve(address(router), amountIn);
        uint256 before = tOut.balanceOf(address(this));
        router.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        got = tOut.balanceOf(address(this)) - before;
        if (got < minOut) revert TooLittleReceived(minOut, got);
        require(tOut.transfer(msg.sender, got), "push");
    }
}

/// @notice Shared V2-07 helpers: reading the `ConfluenceSwap` event, exact balance books, the splitter's plan and
///         the hook's router calldata, so a test can mock either.
abstract contract V207Helpers {
    /// @dev The legs of the last `ConfluenceSwap` emitted by `hook` in `logs`, and whether there was one.
    function _legsFrom(Vm.Log[] memory logs, address hook)
        internal
        pure
        returns (ConfluenceHook.Leg[] memory legs, bool emitted)
    {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != hook || logs[i].topics[0] != ConfluenceHook.ConfluenceSwap.selector) continue;
            (,,,,,,,, legs) = abi.decode(
                logs[i].data, (bool, bool, int256, int24, int24, uint160, uint128, uint24, ConfluenceHook.Leg[])
            );
            emitted = true;
        }
    }

    /// @dev The taker data the hook sends with a leg: exact input, strict threshold `out`, output to the taker.
    function _td(uint256 out) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: address(0),
                isExactIn: true,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: true,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: true,
                threshold: abi.encode(out),
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

    /// @dev SwapVM's exact-input output: fee rounded up on the input, then XYC rounded down.
    function _cpOut(uint256 x, uint256 y, uint32 feeE9, uint256 a) internal pure returns (uint256) {
        uint256 net = a - Math.mulDiv(a, feeE9, 1e9, Math.Rounding.Ceil);
        return net == 0 ? 0 : Math.mulDiv(net, y, x + net);
    }

    function _countStatus(ConfluenceHook.Leg[] memory legs, uint8 code) internal pure returns (uint256 n) {
        for (uint256 i; i < legs.length; i++) {
            if (legs[i].status == code) n++;
        }
    }

    function _sumLegs(ConfluenceHook.Leg[] memory legs) internal pure returns (uint256 sumIn, uint256 sumOut) {
        for (uint256 i; i < legs.length; i++) {
            sumIn += legs[i].amountIn;
            sumOut += legs[i].amountOut;
        }
    }

    function _expectAllStatus(ConfluenceHook.Leg[] memory legs, uint8 code, string memory ctx) internal pure {
        for (uint256 i; i < legs.length; i++) {
            require(legs[i].status == code, string.concat(ctx, ": unexpected leg status"));
            require(legs[i].amountIn == 0 && legs[i].amountOut == 0, string.concat(ctx, ": leg filled"));
        }
    }

    function _burnerCode() internal pure returns (bytes memory) {
        return hex"5b600056"; // JUMPDEST PUSH1 0 JUMP: loops until out of gas
    }
}

/// @notice Fixture shared by the V2-07 and V2-08 split tests: the pool, the makers, the swap runner, the books and the
///         gas helpers. Moved verbatim out of `V207SplitTest` (V2-08 step 0, no behaviour change).
abstract contract SplitBase is RegistryBase, V207Helpers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant USDC_1 = 1e6;
    uint256 internal constant MUMB_1 = 1e18;
    uint32 internal constant FEE_005 = 500_000;
    uint32 internal constant FEE_050 = 5_000_000;
    uint32 internal constant FEE_100 = 10_000_000;
    uint32 internal constant FEE_150 = 15_000_000;
    uint256 internal constant MAX_FUZZ_MAKERS = 6;
    uint256 internal constant COVERAGE_WIDE_SEEDS = 24;
    uint256 internal constant COVERAGE_SEEDS = 32;
    uint256 internal constant M3_TARGET = 991549823315669231761; // v1's hinted best (D-21)

    ConfluenceSplitter internal splitter;
    ConfluenceSplitterOut internal splitterOut;

    struct Run {
        uint256 paid;
        uint256 got;
        ConfluenceHook.Leg[] legs;
        bool emitted;
        uint256 gasUsed;
    }

    /// @dev Exact balances. Index 0 is USDC (currency0), 1 is MUMB.
    struct Book {
        uint256[2] trader;
        uint256[2] hook;
        uint256[2] pm;
        uint256[2][] wallet;
        uint256[2][] virt;
    }

    /// @dev One maker as registered, for books and quotes.
    struct M {
        address who;
        bytes32 hash;
        StrategyTemplate.Params p;
    }

    function setUp() public override {
        super.setUp();
        splitter = hookV2.splitter();
        splitterOut = hookV2.splitterOut();
        vm.prank(deployer);
        mumb.mint(trader, 100_000e18);
    }

    // =====================================================================================================
    // Helpers: the swap and its books
    // =====================================================================================================

    function _run(PoolKey memory k, bool zfo, uint256 amount, bytes memory hookData) internal returns (Run memory r) {
        (address tIn, address tOut) = _io(k, zfo);
        uint256 inB = IERC20(tIn).balanceOf(trader);
        uint256 outB = IERC20(tOut).balanceOf(trader);
        vm.recordLogs();
        uint256 g = gasleft();
        _swap(k, trader, zfo, -int256(amount), hookData);
        r.gasUsed = g - gasleft();
        (r.legs, r.emitted) = _legsFrom(vm.getRecordedLogs(), address(hookV2));
        r.paid = inB - IERC20(tIn).balanceOf(trader);
        r.got = IERC20(tOut).balanceOf(trader) - outB;
    }

    /// @dev The same swap with every maker of `k` unregistered, from the current state; the state is restored.
    function _poolOnly(PoolKey memory k, bool zfo, uint256 amount) internal returns (Run memory r) {
        uint256 s = vm.snapshotState();
        _unregisterAll(k);
        r = _run(k, zfo, amount, "");
        require(vm.revertToStateAndDelete(s), "revert failed");
    }

    function _unregisterAll(PoolKey memory k) internal {
        ConfluenceHook.Slot[] memory slots = hookV2.strategiesOf(k.toId());
        for (uint256 i; i < slots.length; i++) {
            vm.prank(slots[i].maker);
            hookV2.unregister(k);
        }
    }

    function _swapLim(PoolKey memory k, bool zfo, uint256 amount, uint160 limit)
        internal
        returns (uint256 paid, uint256 got)
    {
        vm.startPrank(trader);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        mumb.approve(address(swapRouter), type(uint256).max);
        BalanceDelta d = swapRouter.swap(
            k,
            IPoolManager.SwapParams({zeroForOne: zfo, amountSpecified: -int256(amount), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        (int128 dIn, int128 dOut) = zfo ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        paid = uint256(uint128(-dIn));
        got = uint256(uint128(dOut));
    }

    function _io(PoolKey memory k, bool zfo) internal pure returns (address tIn, address tOut) {
        (tIn, tOut) = zfo
            ? (Currency.unwrap(k.currency0), Currency.unwrap(k.currency1))
            : (Currency.unwrap(k.currency1), Currency.unwrap(k.currency0));
    }

    function _book(M[] memory ms) internal view returns (Book memory b) {
        b.trader = [IERC20(USDC).balanceOf(trader), mumb.balanceOf(trader)];
        b.hook = [IERC20(USDC).balanceOf(address(hookV2)), mumb.balanceOf(address(hookV2))];
        b.pm = [IERC20(USDC).balanceOf(address(manager)), mumb.balanceOf(address(manager))];
        b.wallet = new uint256[2][](ms.length);
        b.virt = new uint256[2][](ms.length);
        for (uint256 j; j < ms.length; j++) {
            b.wallet[j] = [IERC20(USDC).balanceOf(ms[j].who), mumb.balanceOf(ms[j].who)];
            (uint256 vu,) = IAqua(AQUA).rawBalances(ms[j].who, ROUTER, ms[j].hash, USDC);
            (uint256 vm_,) = IAqua(AQUA).rawBalances(ms[j].who, ROUTER, ms[j].hash, address(mumb));
            b.virt[j] = [vu, vm_];
        }
    }

    /// @dev Exact books for a swap in which the trader paid `paid` (the whole input unless the pool stopped early): the
    ///      trader got the legs plus the pool's leg (what left the PoolManager); the PoolManager kept the pool's share;
    ///      each maker moved exactly its leg in wallet and Aqua, each filled leg equals SwapVM's quote from the
    ///      pre-swap balances; the hook holds nothing and every allowance (hook to router, router to Aqua) is 0.
    ///      `ms[j]` must be registry slot j.
    function _assertBooks(Book memory b0, Book memory b1, bool zfo, uint256 paid, Run memory r, M[] memory ms)
        internal
        view
    {
        (uint256 iIn, uint256 iOut) = zfo ? (0, 1) : (1, 0);
        (uint256 sumIn, uint256 sumOut) = _sumLegs(r.legs);
        assertEq(b0.trader[iIn] - b1.trader[iIn], paid, "trader paid the amount");
        assertEq(r.paid, paid, "trader paid the amount (run)");
        uint256 poolLeg = b0.pm[iOut] - b1.pm[iOut];
        assertEq(b1.trader[iOut] - b0.trader[iOut], sumOut + poolLeg, "trader got the legs and the pool leg");
        assertEq(b1.pm[iIn] - b0.pm[iIn], paid - sumIn, "the PoolManager kept the pool's share");
        assertEq(b1.hook[0], 0, "hook USDC");
        assertEq(b1.hook[1], 0, "hook MUMB");
        assertEq(r.legs.length, ms.length, "one leg entry per slot");
        for (uint256 j; j < ms.length; j++) {
            ConfluenceHook.Leg memory l = r.legs[j];
            assertEq(l.strategyHash, ms[j].hash, "slot order");
            assertEq(b1.wallet[j][iIn], b0.wallet[j][iIn] + l.amountIn, "maker wallet in");
            assertEq(b1.wallet[j][iOut], b0.wallet[j][iOut] - l.amountOut, "maker wallet out");
            assertEq(b1.virt[j][iIn], b0.virt[j][iIn] + l.amountIn, "maker Aqua in");
            assertEq(b1.virt[j][iOut], b0.virt[j][iOut] - l.amountOut, "maker Aqua out");
            if (l.status == LegStatus.FILLED) {
                assertEq(
                    l.amountOut,
                    _cpOut(b0.virt[j][iIn], b0.virt[j][iOut], ms[j].p.feeE9, l.amountIn),
                    "leg output = SwapVM's quote"
                );
            } else {
                assertEq(l.amountIn + l.amountOut, 0, "a skipped slot moves nothing");
            }
        }
        _assertClean();
    }

    function _assertClean() internal view {
        assertEq(IERC20(USDC).balanceOf(address(hookV2)), 0, "hook USDC");
        assertEq(mumb.balanceOf(address(hookV2)), 0, "hook MUMB");
        assertEq(address(hookV2).balance, 0, "hook ETH");
        assertEq(IERC20(USDC).allowance(address(hookV2), ROUTER), 0, "hook -> router USDC allowance");
        assertEq(mumb.allowance(address(hookV2), ROUTER), 0, "hook -> router MUMB allowance");
        assertEq(IERC20(USDC).allowance(ROUTER, AQUA), 0, "router -> Aqua USDC allowance");
        assertEq(mumb.allowance(ROUTER, AQUA), 0, "router -> Aqua MUMB allowance");
    }

    // =====================================================================================================
    // Helpers: makers, plans, mocks
    // =====================================================================================================

    function _pf(uint32 feeE9) internal pure returns (StrategyTemplate.Params memory p) {
        p = StrategyTemplate.Params({feeE9: feeE9, bandBps: 200, driftTicks: 300, exclusive: true, salt: 0});
    }

    /// @dev Fund, ship (wallet = virtual) and register `m` on pool `k`.
    function _joinM(PoolKey memory k, address m, uint256 mumbAmt, uint256 usdcAmt, StrategyTemplate.Params memory p)
        internal
        returns (M memory r)
    {
        _fund(m, mumbAmt, usdcAmt);
        uint256[] memory a = new uint256[](2);
        (a[0], a[1]) = (usdcAmt, mumbAmt);
        bytes memory prog = StrategyTemplate.program(p, manager, k, _guard());
        vm.prank(m);
        r.hash = IAqua(AQUA).ship(ROUTER, abi.encode(StrategyTemplate.order(m, prog)), _tokens(), a);
        vm.prank(m);
        hookV2.register(k, p);
        (r.who, r.p) = (m, p);
    }

    /// @dev The three makers of `threeMakers` in v1_demo.json, in vector order (= slot order).
    function _threeMakers() internal returns (M[] memory ms) {
        Vectors.ThreeMakers memory c = Vectors.threeMakers(Vectors.read(Vectors.V1_DEMO), 0);
        ms = new M[](3);
        for (uint256 j; j < 3; j++) {
            Vectors.VenueV memory v = c.makers[j]; // case 0 is USDC in: x = USDC, y = MUMB
            ms[j] = _joinM(keyV2, makers[j], v.y, v.x, _pf(v.feeE9));
        }
    }

    function _fourMakers() internal returns (M[] memory ms) {
        M[] memory three = _threeMakers();
        ms = new M[](4);
        for (uint256 j; j < 3; j++) {
            ms[j] = three[j];
        }
        ms[3] = _joinM(keyV2, makers[3], 1_000e18, 1_000e6, _pf(FEE_100));
    }

    function _order(PoolKey memory k, M memory m) internal view returns (ISwapVM.Order memory) {
        return StrategyTemplate.order(m.who, StrategyTemplate.program(m.p, manager, k, _guard()));
    }

    function _virt(M memory m, bool zfo) internal view returns (uint256 x, uint256 y) {
        (address tIn, address tOut) = zfo ? (USDC, address(mumb)) : (address(mumb), USDC);
        (x,) = IAqua(AQUA).rawBalances(m.who, ROUTER, m.hash, tIn);
        (y,) = IAqua(AQUA).rawBalances(m.who, ROUTER, m.hash, tOut);
    }

    function _lim(bool zfo) internal pure returns (uint160) {
        return zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @dev The splitter's plan for this swap, at the anchor the hook will use (`anchorOfX` is the post-update value).
    function _plan(PoolKey memory k, bool zfo, uint256 amount) internal view returns (Plan memory) {
        (int24 s, int56 e,) = hookV2.anchorOfX(k.toId());
        return splitter.planExactIn(k, zfo, _lim(zfo), amount, s, e);
    }

    function _copy(Plan memory p) internal pure returns (Plan memory q) {
        q = abi.decode(abi.encode(p), (Plan));
    }

    function _statuses(Plan memory p, uint256 n) internal pure returns (ConfluenceHook.Leg[] memory legs) {
        legs = new ConfluenceHook.Leg[](n);
        for (uint256 i; i < n; i++) {
            legs[i].status = uint8(p.status[i]);
        }
    }

    /// @dev The router call the hook makes for `m`'s leg reverts.
    function _mockLegRevert(PoolKey memory k, M memory m, bool zfo, uint256 a, uint256 out) internal {
        (address tIn, address tOut) = _io(k, zfo);
        vm.mockCallRevert(
            ROUTER, abi.encodeCall(ISwapVM.swap, (_order(k, m), tIn, tOut, a, _td(out))), abi.encode("mocked revert")
        );
    }

    /// @dev Maker 1's leg forged to 1.5x its band cap, priced exactly (so the strict threshold passes and the guard
    ///      is what refuses); maker 2's leg dropped to make room; the pool quotes forged so the never-worse check passes.
    function _forgePastBand(Plan memory p, M[] memory ms, uint256 amount) internal view returns (Plan memory q) {
        q = _copy(p);
        (uint256 x, uint256 y) = _virt(ms[1], true);
        uint256 a = p.capIn[1] * 3 / 2;
        (q.amountIn[1], q.amountOut[1], q.capIn[1]) = (a, _cpOut(x, y, ms[1].p.feeE9, a), a);
        (q.amountIn[2], q.amountOut[2], q.status[2]) = (0, 0, LegStatus.SKIP_MIN_LEG);
        q.poolIn = amount - q.amountIn[0] - a;
        (q.poolOnlyOut, q.tail) = (0, 0);
    }

    /// @dev Mocks the splitter's return with `ret` (or a revert) and checks the swap is exact pool-only.
    function _expectPoolOnly(
        bytes memory ret,
        bool reverts,
        bool zfo,
        uint256 amount,
        Run memory po,
        M[] memory ms,
        string memory ctx
    ) internal {
        uint256 s = vm.snapshotState();
        bytes memory sel = abi.encodeWithSelector(ConfluenceSplitter.planExactIn.selector);
        if (reverts) vm.mockCallRevert(address(splitter), sel, "garbage");
        else vm.mockCall(address(splitter), sel, ret);
        Book memory b0 = _book(ms);
        Run memory r = _run(keyV2, zfo, amount, "");
        _assertBooks(b0, _book(ms), zfo, po.paid, r, ms);
        _expectAllStatus(r.legs, LegStatus.SKIP_PLAN, ctx);
        assertEq(r.got, po.got, string.concat(ctx, ": pool-only output"));
        _assertClean();
        vm.clearMockedCalls();
        vm.revertToState(s);
    }

    // =====================================================================================================
    // Helpers: pools and anchors
    // =====================================================================================================

    /// @dev Records the anchor with a 1-raw-unit USDC swap: the 0.30% fee takes it all, so the price does not move.
    function _initExact(PoolKey memory k) internal {
        _swap(k, trader, true, -1, "");
    }

    function _nextBlock(uint256 dt) internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + dt);
    }

    /// @dev MUMB raw for `usdcRaw` at the price of `tick` (MUMB raw per USDC raw), rounded down.
    function _mumbAt(uint256 usdcRaw, int24 tick) internal pure returns (uint256) {
        uint256 s = TickMath.getSqrtPriceAtTick(tick);
        return FullMath.mulDiv(FullMath.mulDiv(usdcRaw, s, 2 ** 96), s, 2 ** 96);
    }

    struct Pos {
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }

    function _v1Positions() internal view returns (Pos[] memory pos) {
        pos = new Pos[](1);
        pos[0] = Pos(tickLower, tickUpper, manager.getLiquidity(idV2));
    }

    /// @dev A hooked MUMB/USDC pool (spacing 30, so its id differs from keyV2) whose walk is truncated: deep
    ///      liquidity on [C-480, C+480], seven small positions making ticks at C-60 ... C-420 and C+60 ... C+420,
    ///      gaps, then deep liquidity on [C-1200, C-540] and [C+540, C+1200]. C is the v1 anchor tick floored to 60.
    function _gapKey() internal returns (PoolKey memory) {
        int24 c = _floorToSpacing(TickMath.getTickAtSqrtPrice(anchorSqrtPriceX96(true)));
        Pos[] memory pos = new Pos[](10);
        pos[0] = Pos(c - 480, c + 480, 4e16);
        for (uint256 i; i < 7; i++) {
            int24 d = 60 * int24(int256(i + 1));
            pos[i + 1] = Pos(c - d, c + d, 4e14);
        }
        pos[8] = Pos(c - 1200, c - 540, 4e16);
        pos[9] = Pos(c + 540, c + 1200, 4e16);
        return _newHookedPool(3000, 30, pos);
    }

    function _newHookedPool(uint24 fee, int24 spacing, Pos[] memory pos) internal returns (PoolKey memory k) {
        k = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(address(mumb)),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(address(hookV2))
        });
        manager.initialize(k, anchorSqrtPriceX96(true));
        deal(USDC, deployer, 1e15);
        vm.startPrank(deployer);
        mumb.mint(deployer, 1e27);
        IERC20(USDC).approve(address(liquidityRouter), type(uint256).max);
        mumb.approve(address(liquidityRouter), type(uint256).max);
        for (uint256 i; i < pos.length; i++) {
            liquidityRouter.modifyLiquidity(
                k,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: pos[i].lower,
                    tickUpper: pos[i].upper,
                    liquidityDelta: int256(uint256(pos[i].liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
        }
        vm.stopPrank();
    }

    function _addFullRange(PoolKey memory k, uint256 usdcAmt, uint256 mumbAmt) internal {
        int24 lo = (TickMath.MIN_TICK / k.tickSpacing) * k.tickSpacing;
        int24 hi = (TickMath.MAX_TICK / k.tickSpacing) * k.tickSpacing;
        (uint160 sqrtP,,,) = manager.getSlot0(k.toId());
        uint128 liq = _liquidityFor(sqrtP, lo, hi, usdcAmt, mumbAmt);
        deal(USDC, deployer, IERC20(USDC).balanceOf(deployer) + usdcAmt * 2);
        vm.startPrank(deployer);
        mumb.mint(deployer, mumbAmt * 2);
        IERC20(USDC).approve(address(liquidityRouter), type(uint256).max);
        mumb.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lo, tickUpper: hi, liquidityDelta: int256(uint256(liq)), salt: bytes32("full")
            }),
            ""
        );
        vm.stopPrank();
    }

    function _liquidityFor(uint160 sqrtP, int24 lo, int24 hi, uint256 a0, uint256 a1) internal pure returns (uint128) {
        uint160 sa = TickMath.getSqrtPriceAtTick(lo);
        uint160 sb = TickMath.getSqrtPriceAtTick(hi);
        // L from amount0 over [sqrtP, sb] and from amount1 over [sa, sqrtP]; the smaller.
        uint256 l0 = FullMath.mulDiv(FullMath.mulDiv(a0, sqrtP, 2 ** 96), sb, sb - sqrtP);
        uint256 l1 = FullMath.mulDiv(a1, 2 ** 96, sqrtP - sa);
        return uint128(Math.min(l0, l1));
    }

    function _walked(PoolKey memory k, bool zfo) internal view returns (uint256 w) {
        PoolVenue.Pool memory p = PoolVenue.read(manager, k.toId(), k.tickSpacing, zfo, _lim(zfo));
        for (uint256 i; i < p.segments.length; i++) {
            w += p.segments[i].capIn;
        }
    }

    // =====================================================================================================
    // Helpers: fuzz body, gas
    // =====================================================================================================

    /// @dev Returns 0 if a leg filled, 1 if the plan fell back as not better, 2 if nothing was planned. `thin` is the
    ///      coverage-only generator: 1-6 makers 200-3,000 USDC deep with a 6% band, amount 1-300 units past the walk.
    function _neverWorseCase(uint256 seed, bool zfo, uint256 amountRaw, uint8 nRaw, bool gap, bool thin)
        internal
        returns (uint8 cat)
    {
        PoolKey memory k = gap ? _gapKey() : keyV2;
        _initExact(k);
        int24 snap;
        (snap,,) = hookV2.anchorOf(k.toId());
        uint256 n = bound(nRaw, thin ? 1 : 0, MAX_FUZZ_MAKERS);
        uint32[5] memory fees = [uint32(500_000), 1_000_000, 3_000_000, 5_000_000, 10_000_000];
        for (uint256 i; i < n; i++) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            uint256 usdcRaw = (thin ? bound(h, 200, 3_000) : bound(h, 1_000, 200_000)) * USDC_1;
            int24 off = int24(int256(bound(h >> 64, 0, 300))) - 150;
            StrategyTemplate.Params memory p = _pf(fees[(h >> 128) % 5]);
            if (thin) p.bandBps = 600;
            _joinM(k, makers[i], _mumbAt(usdcRaw, snap + off), usdcRaw, p);
        }
        uint256 unit = zfo ? USDC_1 : MUMB_1;
        uint256 amount = thin ? _walked(k, zfo) + bound(amountRaw, 1, 300) * unit : bound(amountRaw, 1, 3_000 * unit);
        Run memory po = _poolOnly(k, zfo, amount);
        Run memory r = _run(k, zfo, amount, "");
        assertGe(r.got, po.got, "never worse than the real pool-only swap");
        (uint256 sumIn,) = _sumLegs(r.legs);
        if (sumIn == 0) {
            assertEq(r.got, po.got, "no leg: exactly pool-only");
            assertEq(r.paid, po.paid, "no leg: same input");
        }
        assertEq(IERC20(USDC).balanceOf(address(hookV2)) + mumb.balanceOf(address(hookV2)), 0, "hook holds nothing");
        if (sumIn > 0) return 0;
        return _countStatus(r.legs, LegStatus.SKIP_NOT_BETTER) > 0 ? 1 : 2;
    }

    function _coldRun(PoolKey memory k, bool zfo, uint256 amount) internal returns (Run memory r) {
        address[8] memory touched =
            [address(manager), address(hookV2), address(splitter), AQUA, ROUTER, USDC, address(mumb), _guard()];
        for (uint256 i; i < touched.length; i++) {
            vm.cool(touched[i]);
        }
        for (uint256 i; i < 6; i++) {
            vm.cool(makers[i]);
        }
        r = _run(k, zfo, amount, "");
    }

    function _logGas(string memory label, uint256 g) internal pure {
        if (g > 1_000_000) console2.log(string.concat(label, " [FLAG: above 1,000,000]"), g);
        else console2.log(label, g);
    }

    /// @dev v1's hinted swap on the v1 pool: Priya's v1 band strategy shipped and registered on the v1 hook, then a
    ///      1,000 USDC swap with hint 550,000,000, measured as `_coldRun` does.
    function _v1HintedGas() internal returns (uint256 used) {
        PoolPriceBandExtruction band = new PoolPriceBandExtruction();
        ISwapVM.Order memory o =
            _buildOrder(priya, _buildBandProgram(FEE_0_30_PCT, address(band), band.build(manager, key, 200)));
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(mumb), USDC);
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (100_000e18, 100_000e6);
        vm.startPrank(priya);
        mumb.approve(AQUA, type(uint256).max);
        IERC20(USDC).approve(AQUA, type(uint256).max);
        IAqua(AQUA).ship(ROUTER, abi.encode(o), tokens, amounts);
        hook.registerOrder(key, o);
        vm.stopPrank();
        address[7] memory touched = [address(manager), address(hook), AQUA, ROUTER, USDC, address(mumb), address(band)];
        for (uint256 i; i < touched.length; i++) {
            vm.cool(touched[i]);
        }
        vm.cool(priya);
        uint256 g = gasleft();
        _swap(key, trader, true, -int256(1_000 * USDC_1), abi.encode(uint256(550_000_000)));
        used = g - gasleft();
    }

    /// @dev F06's limits (285,000 to 500,000 in steps of 5,000, then up to 3,000,000) plus 4,000,000 and 6,000,000,
    ///      for a 1,000 USDC swap. At every limit where the pool-only swap passes, the split swap must pass.
    function _sweepGasLimits(string memory label) internal returns (uint256 filled) {
        uint256 n = (500_000 - 285_000) / 5_000 + 1;
        uint256[] memory limits = new uint256[](n + 15);
        for (uint256 i; i < n; i++) {
            limits[i] = 285_000 + i * 5_000;
        }
        // V2-11: the hook's gate rose to RESERVE_MAX + MIN_LEG_GAS (1,290,000, D-40), so five limits were added above it
        // (1,750,000 to 5,000,000) to keep the sweep reaching limits where the legs fill; the existing ones are unchanged.
        uint256[15] memory high = [
            uint256(550_000),
            600_000,
            700_000,
            800_000,
            1_000_000,
            1_500_000,
            1_750_000,
            2_000_000,
            2_500_000,
            3_000_000,
            3_500_000,
            4_000_000,
            4_500_000,
            5_000_000,
            6_000_000
        ];
        for (uint256 i; i < 15; i++) {
            limits[n + i] = high[i];
        }
        uint256 checked;
        for (uint256 i; i < limits.length; i++) {
            uint256 s = vm.snapshotState();
            _unregisterAll(keyV2);
            bool poolOk = _tryAtLimit(limits[i]);
            vm.revertToState(s);
            if (!poolOk) continue;
            checked++;
            vm.recordLogs();
            bool ok = _tryAtLimit(limits[i]);
            assertTrue(ok, string.concat(label, ": split swap reverted at gas limit ", vm.toString(limits[i])));
            (ConfluenceHook.Leg[] memory legs,) = _legsFrom(vm.getRecordedLogs(), address(hookV2));
            if (_countStatus(legs, LegStatus.FILLED) > 0) filled++;
            _assertClean();
            vm.revertToState(s);
        }
        assertGe(checked, 50, string.concat(label, ": precondition: the pool alone passes at (nearly) every limit"));
    }

    function _tryAtLimit(uint256 limit) internal returns (bool ok) {
        vm.startPrank(trader);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        try swapRouter.swap{gas: limit}(
            keyV2,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(1_000 * USDC_1), sqrtPriceLimitX96: _lim(true)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            ok = true;
        } catch {
            ok = false;
        }
        vm.stopPrank();
    }
}
