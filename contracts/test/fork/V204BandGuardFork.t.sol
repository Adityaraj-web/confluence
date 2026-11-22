// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {BPS} from "@1inch/swap-vm/src/instructions/Fee.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BandGuardV2, TakerNotHook, AnchorDrift, BandExceeded} from "../../src/BandGuardV2.sol";
import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {AnchorLib} from "../../src/libraries/AnchorLib.sol";
import {PoolPriceBandExtruction} from "../../src/v1/PoolPriceBandExtruction.sol";
import {PoolBase} from "../base/PoolBase.t.sol";
import {StrategyLib} from "../base/StrategyLib.sol";
import {TakerHelper} from "../base/TakerHelper.sol";

/// @notice V2-04 on the mainnet fork: BandGuardV2 inside Priya's program on the canonical router, reading the v2
///         hook's anchor on a real v4 pool. Gate M2 is `test_V204_sameBlockAttackRefused`. Choices are in D-32.
contract V204BandGuardForkTest is PoolBase, StrategyLib {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant H = 60;
    uint256 internal constant SHIPPED_MUMB = 100_000e18;
    /// @dev Fair: the curve's spot is the pool's 1 USDC per MUMB.
    uint256 internal constant FAIR_USDC = 100_000e6;
    /// @dev Stale: the curve sells MUMB at 0.95 USDC while the market is at 1.0.
    uint256 internal constant STALE_USDC = 95_000e6;
    uint256 internal constant FILL_USDC = 1_000e6;
    /// @dev Moves the pool about 3.4% (about 350 ticks) toward the stale curve.
    uint256 internal constant PUSH_MUMB = 1_500e18;
    /// @dev F02's fill of 1,000 USDC against the fair balances (F03 checks the same figure).
    uint256 internal constant EXPECTED_MUMB_OUT = 987158034397061298850;
    uint16 internal constant BAND = 200;
    uint16 internal constant DRIFT = 300;
    uint256 internal constant Q192 = 2 ** 192;

    BandGuardV2 internal guard;
    PoolPriceBandExtruction internal v1band;
    TakerHelper internal helper;
    ConfluenceHook internal hookV2;
    PoolKey internal keyV2;
    PoolId internal idV2;

    constructor() StrategyLib(AQUA) {}

    function setUp() public override {
        super.setUp();
        hookV2 = _deployHookV2();
        keyV2 = _createPool(IHooks(address(hookV2)));
        idV2 = keyV2.toId();
        guard = new BandGuardV2();
        v1band = new PoolPriceBandExtruction();
        helper = new TakerHelper(ISwapVM(ROUTER));

        vm.startPrank(priya);
        mumb.approve(AQUA, type(uint256).max);
        IERC20(USDC).approve(AQUA, type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- helpers

    function _ship(bytes memory program, uint256 usdcAmount)
        internal
        returns (ISwapVM.Order memory order, bytes32 strategyHash)
    {
        order = _buildOrder(priya, program);
        address[] memory tokens = new address[](2);
        tokens[0] = address(mumb);
        tokens[1] = USDC;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SHIPPED_MUMB;
        amounts[1] = usdcAmount;
        vm.prank(priya);
        strategyHash = IAqua(AQUA).ship(ROUTER, abi.encode(order), tokens, amounts);
    }

    function _shipGuard(PoolKey memory k, uint16 band, uint16 drift, uint8 flags, uint256 usdcAmount)
        internal
        returns (ISwapVM.Order memory, bytes32)
    {
        bytes memory args = guard.build(manager, k, band, drift, flags);
        return _ship(_buildBandProgram(FEE_0_30_PCT, address(guard), args), usdcAmount);
    }

    /// @dev The attacker (`trader`) sells MUMB into the pool: the pool price falls toward the stale curve.
    function _push() internal {
        _swap(keyV2, trader, !usdcForMumb(), -int256(PUSH_MUMB), "");
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(idV2);
    }

    function _next(uint256 dt) internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    function _fund(uint256 usdc) internal {
        deal(USDC, address(helper), usdc);
    }

    function _netOfFee(uint256 amountIn) internal pure returns (uint256) {
        return amountIn - Math.ceilDiv(amountIn * FEE_0_30_PCT, BPS);
    }

    /// @dev What the guard sees for `FILL_USDC` against the curve (`usdcAmount`, `SHIPPED_MUMB`): net-of-fee input
    ///      (D-15), as currency1 per currency0 in the X192 scale (both sqrt prices here are below 2^127).
    function _expectedExec(uint256 usdcAmount) internal view returns (uint256) {
        uint256 net = _netOfFee(FILL_USDC);
        uint256 out = (net * SHIPPED_MUMB) / (usdcAmount + net);
        return usdcIsCurrency0 ? FullMath.mulDiv(out, Q192, net) : FullMath.mulDiv(net, Q192, out);
    }

    function _refX192(int24 snapTick) internal pure returns (uint256) {
        uint256 s = TickMath.getSqrtPriceAtTick(snapTick);
        require(s < 2 ** 127, "test premise: X192 scale");
        return s * s;
    }

    function _expectedOut(uint256 usdcAmount) internal pure returns (uint256) {
        uint256 net = _netOfFee(FILL_USDC);
        return (net * SHIPPED_MUMB) / (usdcAmount + net);
    }

    function _decodeExceeded(bytes memory r) internal pure returns (uint256 exec, uint256 ref, uint16 band) {
        require(r.length == 100 && bytes4(r) == BandExceeded.selector, "not BandExceeded");
        assembly ("memory-safe") {
            exec := mload(add(r, 36))
            ref := mload(add(r, 68))
            band := mload(add(r, 100))
        }
    }

    function _takerData(uint256 minOut) internal view returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: address(hookV2),
                isExactIn: true,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: true,
                threshold: abi.encode(minOut),
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

    struct Raw {
        uint40 ts;
        uint64 blk;
        int24 snap;
        int56 emaX;
    }

    function _stored() internal view returns (Raw memory r) {
        uint256 w = uint256(vm.load(address(hookV2), keccak256(abi.encode(PoolId.unwrap(idV2), uint256(0)))));
        r.ts = uint40(w);
        r.blk = uint64(w >> 40);
        r.snap = int24(uint24(w >> 104));
        r.emaX = int56(uint56(w >> 128));
    }

    function _assertHoldsNothing(address who, string memory name) internal view {
        (uint256 m, uint256 u) = balances(who);
        assertEq(m, 0, string.concat(name, " MUMB"));
        assertEq(u, 0, string.concat(name, " USDC"));
    }

    // ---------------------------------------------------------------- the anchor view (carry-over 1)

    function test_V204_anchorOfXEqualsStored() public {
        // Before the block's first swap: computed from slot0, not stored.
        int24 t0 = _tick();
        (int24 s0, int56 e0, bool f0) = hookV2.anchorOfX(idV2);
        assertFalse(f0, "lazy");
        assertEq(s0, t0, "snapshot is slot0");
        assertEq(e0, int56(t0) * 65536, "first touch: ema = snapshot, in fixed point");

        _swap(keyV2, trader, usdcForMumb(), -int256(FILL_USDC), "");
        Raw memory st = _stored();
        assertEq(st.snap, s0, "stored snapshot");
        assertEq(st.emaX, e0, "stored ema");
        (int24 s1, int56 e1, bool f1) = hookV2.anchorOfX(idV2);
        assertTrue(f1, "stored this block");
        assertEq(s1, s0);
        assertEq(e1, e0);

        // A later block after a gap: the view before the swap equals what the swap stores.
        _next(37);
        int24 t1 = _tick();
        assertTrue(t1 != t0, "the first swap moved slot0");
        (int24 s2, int56 e2, bool f2) = hookV2.anchorOfX(idV2);
        assertFalse(f2);
        assertEq(s2, t1);
        assertTrue(e2 != int56(t1) * 65536 && e2 != e0, "the EMA decayed part of the way");
        _swap(keyV2, trader, !usdcForMumb(), -int256(FILL_USDC), "");
        st = _stored();
        assertEq(st.snap, s2, "stored snapshot, block 2");
        assertEq(st.emaX, e2, "stored ema, block 2");

        // `anchorOf` is the same anchor, rounded.
        (int24 rs, int24 re, bool rf) = hookV2.anchorOf(idV2);
        assertEq(rs, s2);
        assertEq(re, AnchorLib.emaTick(e2));
        assertTrue(rf);
    }

    // ---------------------------------------------------------------- taker

    function test_V204_exclusiveRefusesOtherTakers() public {
        (ISwapVM.Order memory order, bytes32 strategyHash) = _shipGuard(keyV2, BAND, DRIFT, 1, FAIR_USDC);

        // An outside taker: refused on swap and on quote, and nothing moves.
        _fund(FILL_USDC);
        bytes memory refused = abi.encodeWithSelector(TakerNotHook.selector, address(helper));
        vm.expectRevert(refused);
        helper.swapExactIn(order, USDC, address(mumb), FILL_USDC, 0, trader);
        vm.expectRevert(refused);
        helper.quoteExactIn(order, USDC, address(mumb), FILL_USDC, 0);

        // The hook as taker: quote and swap both pass and agree.
        deal(USDC, address(hookV2), FILL_USDC);
        vm.startPrank(address(hookV2));
        IERC20(USDC).approve(ROUTER, FILL_USDC);
        (, uint256 quotedOut,) = ISwapVM(ROUTER).quote(order, USDC, address(mumb), FILL_USDC, _takerData(0));
        (uint256 swappedIn, uint256 swappedOut,) =
            ISwapVM(ROUTER).swap(order, USDC, address(mumb), FILL_USDC, _takerData(0));
        IERC20(USDC).approve(ROUTER, 0);
        mumb.transfer(trader, swappedOut);
        vm.stopPrank();

        assertEq(swappedIn, FILL_USDC, "amountIn");
        assertEq(swappedOut, EXPECTED_MUMB_OUT, "amountOut");
        assertEq(quotedOut, swappedOut, "quote == swap");
        (uint256 walletMumb, uint256 walletUsdc) = balances(priya);
        assertEq(walletMumb, PRIYA_MUMB - EXPECTED_MUMB_OUT, "Priya wallet MUMB");
        assertEq(walletUsdc, PRIYA_USDC + FILL_USDC, "Priya wallet USDC");
        (uint256 vMumb, uint256 vUsdc) = IAqua(AQUA).safeBalances(priya, ROUTER, strategyHash, address(mumb), USDC);
        assertEq(vMumb, SHIPPED_MUMB - EXPECTED_MUMB_OUT, "virtual MUMB");
        assertEq(vUsdc, FAIR_USDC + FILL_USDC, "virtual USDC");
        _assertHoldsNothing(address(hookV2), "hook");
        // The refused helper still holds its USDC.
        (, uint256 helperUsdc) = balances(address(helper));
        assertEq(helperUsdc, FILL_USDC, "helper USDC");
    }

    // ---------------------------------------------------------------- snapshot, not spot

    function test_V204_bandUsesSnapshotNotSpot() public {
        int24 before_ = _tick();
        (ISwapVM.Order memory fair,) = _shipGuard(keyV2, BAND, DRIFT, 0, FAIR_USDC);
        // Aqua refuses the same strategy bytes twice, so the stale one carries a different (still ample) drift limit.
        (ISwapVM.Order memory stale,) = _shipGuard(keyV2, BAND, DRIFT + 1, 0, STALE_USDC);

        _push();
        int24 spot = _tick();
        assertGt(before_ > spot ? before_ - spot : spot - before_, 300, "the push moved slot0 by more than 3%");

        // The fair curve (price 1.0097 net of fee) is 4.6% from spot but 1% from the snapshot: it fills.
        _fund(FILL_USDC);
        (, uint256 out,) = helper.swapExactIn(fair, USDC, address(mumb), FILL_USDC, 0, trader);
        assertEq(out, EXPECTED_MUMB_OUT, "fills against the snapshot");

        // The stale curve (0.96) is 0.6% from spot but 4% from the snapshot: refused, with the snapshot as reference.
        _fund(FILL_USDC);
        try helper.swapExactIn(stale, USDC, address(mumb), FILL_USDC, 0, trader) {
            fail("the stale curve must be refused");
        } catch (bytes memory r) {
            (uint256 exec, uint256 ref, uint16 band) = _decodeExceeded(r);
            assertEq(ref, _refX192(before_), "reference is the snapshot price");
            assertTrue(ref != _refX192(spot), "premise: spot differs");
            assertEq(exec, _expectedExec(STALE_USDC), "exec");
            assertEq(band, BAND);
        }
        (int24 snap,,) = hookV2.anchorOfX(idV2);
        assertEq(snap, before_, "snapshot unmoved");
    }

    function test_V204_quoteEqualsSwapWithinBlock() public {
        (ISwapVM.Order memory order, bytes32 strategyHash) = _shipGuard(keyV2, BAND, DRIFT, 0, FAIR_USDC);
        _fund(FILL_USDC);

        // Before the block's first swap the anchor is computed lazily; the quote is a STATICCALL through the router.
        (,, bool fresh) = hookV2.anchorOfX(idV2);
        assertFalse(fresh, "premise: lazy");
        (uint256 q0In, uint256 q0Out, bytes32 q0Hash) = helper.quoteExactIn(order, USDC, address(mumb), FILL_USDC, 0);

        _push(); // stores the anchor and moves spot

        (uint256 q1In, uint256 q1Out, bytes32 q1Hash) = helper.quoteExactIn(order, USDC, address(mumb), FILL_USDC, 0);
        (uint256 sIn, uint256 sOut, bytes32 sHash) =
            helper.swapExactIn(order, USDC, address(mumb), FILL_USDC, 0, trader);

        assertEq(q0In, sIn);
        assertEq(q1In, sIn);
        assertEq(q0Out, sOut, "quote before the first swap equals the swap");
        assertEq(q1Out, sOut, "quote after the push equals the swap");
        assertEq(q0Hash, strategyHash);
        assertEq(q1Hash, sHash);
        assertEq(sHash, strategyHash);
        assertEq(sOut, EXPECTED_MUMB_OUT);
    }

    // ---------------------------------------------------------------- drift

    function test_V204_driftRefusal() public {
        uint16 limit = 100;
        (ISwapVM.Order memory order,) = _shipGuard(keyV2, BAND, limit, 0, STALE_USDC);
        _push(); // block N: the snapshot is the pre-push price

        // Block N+1, 12 s later: the snapshot is the pushed price, the EMA has only moved a little toward it.
        _next(12);
        (int24 snap, int56 emaX,) = hookV2.anchorOfX(idV2);
        int256 gap = int256(snap) * 65536 - int256(emaX);
        assertGt(gap < 0 ? -gap : gap, int256(uint256(limit)) * 65536, "premise: drift above the limit");

        _fund(FILL_USDC);
        bytes memory refused = abi.encodeWithSelector(AnchorDrift.selector, snap, emaX, limit);
        vm.expectRevert(refused);
        helper.swapExactIn(order, USDC, address(mumb), FILL_USDC, 0, trader);
        vm.expectRevert(refused);
        helper.quoteExactIn(order, USDC, address(mumb), FILL_USDC, 0);

        // 16 half-lives later the EMA has caught up (the cut-off, D-31): the stale curve is within 2% of the pushed
        // price and fills.
        _next(16 * H);
        (int24 snap2, int56 ema2,) = hookV2.anchorOfX(idV2);
        assertEq(ema2, int56(snap2) * 65536, "premise: EMA on the snapshot");
        (, uint256 out,) = helper.swapExactIn(order, USDC, address(mumb), FILL_USDC, 0, trader);
        assertEq(out, _expectedOut(STALE_USDC), "fills once the drift is gone");
    }

    // ---------------------------------------------------------------- a wrong pool never reads spot (carry-over 3)

    function test_V204_uninitialisedPoolRefuses() public {
        // The hook's pool id for a key that was never initialised: the hook reverts, so the fill fails.
        (address c0, address c1) = sortedPair();
        PoolKey memory ghost = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12_345, 60, IHooks(address(hookV2)));
        (ISwapVM.Order memory order,) = _shipGuard(ghost, BAND, DRIFT, 0, FAIR_USDC);
        _fund(FILL_USDC);
        vm.expectRevert(ConfluenceHook.PoolNotInitialized.selector);
        helper.swapExactIn(order, USDC, address(mumb), FILL_USDC, 0, trader);
        vm.expectRevert(ConfluenceHook.PoolNotInitialized.selector);
        helper.quoteExactIn(order, USDC, address(mumb), FILL_USDC, 0);

        // An initialised pool that does not use the hook: `key.hooks` is not the hook, so there is no anchor to
        // read. The guard refuses; it never reads spot for it.
        PoolKey memory plain = _createPool(IHooks(address(0)));
        (ISwapVM.Order memory order2,) = _shipGuard(plain, BAND, DRIFT, 0, FAIR_USDC);
        vm.expectRevert();
        helper.swapExactIn(order2, USDC, address(mumb), FILL_USDC, 0, trader);
        vm.expectRevert();
        helper.quoteExactIn(order2, USDC, address(mumb), FILL_USDC, 0);
    }

    // ---------------------------------------------------------------- gate M2

    /// @dev One block. The attacker sells 1,500 MUMB into the pool (spot falls about 3.4%), buys MUMB from Priya's
    ///      stale curve through the canonical router as an ordinary taker, then buys back exactly the MUMB it sold.
    ///      With v1's band (reads spot) the fill passes and the attacker profits; with BandGuardV2 (reads the
    ///      snapshot, which the push did not move) it reverts on the band.
    function test_V204_sameBlockAttackRefused() public {
        uint256 start = vm.snapshotState();

        // ---- v1: PoolPriceBandExtruction, spot reference
        bytes memory v1args = v1band.build(manager, keyV2, BAND);
        (ISwapVM.Order memory v1order, bytes32 v1hash) =
            _ship(_buildBandProgram(FEE_0_30_PCT, address(v1band), v1args), STALE_USDC);
        (uint256 mumb0, uint256 usdc0) = balances(trader);

        _push();
        vm.prank(trader);
        IERC20(USDC).transfer(address(helper), FILL_USDC);
        (, uint256 got,) = helper.swapExactIn(v1order, USDC, address(mumb), FILL_USDC, 0, trader);
        _swap(keyV2, trader, usdcForMumb(), int256(PUSH_MUMB), ""); // exact output: back to the MUMB it sold

        (uint256 mumb1, uint256 usdc1) = balances(trader);
        assertEq(got, _expectedOut(STALE_USDC), "v1 fill: the stale curve's output");
        assertEq(mumb1, mumb0 + got, "attacker keeps exactly the MUMB bought from Priya");
        // Profit in USDC raw units, valuing the MUMB at the block-start price of 1 USDC (1e12 raw MUMB per raw USDC).
        int256 profit = int256(usdc1) - int256(usdc0) + int256((mumb1 - mumb0) / 1e12);
        emit log_named_int("v1 attacker profit (USDC raw, 6 decimals)", profit);
        assertGt(profit, 0, "v1: the attack profits");
        (uint256 walletMumb, uint256 walletUsdc) = balances(priya);
        assertEq(walletMumb, PRIYA_MUMB - got, "v1: Priya wallet MUMB");
        assertEq(walletUsdc, PRIYA_USDC + FILL_USDC, "v1: Priya wallet USDC");
        (uint256 vMumb, uint256 vUsdc) = IAqua(AQUA).safeBalances(priya, ROUTER, v1hash, address(mumb), USDC);
        assertEq(vMumb, SHIPPED_MUMB - got, "v1: virtual MUMB");
        assertEq(vUsdc, STALE_USDC + FILL_USDC, "v1: virtual USDC");
        _assertHoldsNothing(address(helper), "v1 helper");
        _assertHoldsNothing(address(hookV2), "v1 hook");

        // ---- v2: BandGuardV2, snapshot reference
        vm.revertToState(start);
        (ISwapVM.Order memory v2order, bytes32 v2hash) = _shipGuard(keyV2, BAND, DRIFT, 0, STALE_USDC);
        int24 snapTick = _tick();
        (mumb0, usdc0) = balances(trader);

        _push();
        (int24 snapAfter,,) = hookV2.anchorOfX(idV2);
        assertEq(snapAfter, snapTick, "the push did not move the snapshot");
        vm.prank(trader);
        IERC20(USDC).transfer(address(helper), FILL_USDC);

        bytes memory refused =
            abi.encodeWithSelector(BandExceeded.selector, _expectedExec(STALE_USDC), _refX192(snapTick), BAND);
        vm.expectRevert(refused);
        helper.swapExactIn(v2order, USDC, address(mumb), FILL_USDC, 0, trader);

        // Nothing moved: the helper still holds the USDC, Priya's wallet and virtual balances are untouched.
        (, uint256 helperUsdc) = balances(address(helper));
        assertEq(helperUsdc, FILL_USDC, "v2: helper USDC");
        (walletMumb, walletUsdc) = balances(priya);
        assertEq(walletMumb, PRIYA_MUMB, "v2: Priya wallet MUMB");
        assertEq(walletUsdc, PRIYA_USDC, "v2: Priya wallet USDC");
        (vMumb, vUsdc) = IAqua(AQUA).safeBalances(priya, ROUTER, v2hash, address(mumb), USDC);
        assertEq(vMumb, SHIPPED_MUMB, "v2: virtual MUMB");
        assertEq(vUsdc, STALE_USDC, "v2: virtual USDC");
        _assertHoldsNothing(address(hookV2), "v2 hook");
    }
}
