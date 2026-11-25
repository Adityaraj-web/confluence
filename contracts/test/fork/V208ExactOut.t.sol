// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BandGuardV2} from "../../src/BandGuardV2.sol";
import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {LegStatus, Plan} from "../../src/ConfluenceSplitter.sol";
import {MakerVenue} from "../../src/libraries/MakerVenue.sol";
import {PoolVenue} from "../../src/libraries/PoolVenue.sol";
import {StrategyTemplate} from "../../src/libraries/StrategyTemplate.sol";
import {SplitBase} from "../base/SplitBase.t.sol";
import {Vectors} from "../base/Vectors.sol";
import {MockAnchorHook} from "../unit/V204BandGuard.t.sol";

/// @dev Tick of 1 USDC (6 decimals) = 1 MUMB (18 decimals): price 1e12 currency1 per currency0 (as V2-06).
int24 constant TICK_6_18_OUT = 276324;

/// @notice V2-08, no fork: the exact-output safe cap (`MakerVenue.capsOut`, D-36) against the REAL `BandGuardV2`
///         fed exact-output registers (net input from SwapVM's ceiling, the exact output).
contract V208BandCapOutTest is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant PM = address(0x9999);
    address internal constant TOKEN0 = address(0x1000);
    address internal constant TOKEN1 = address(0x2000);
    uint24 internal constant LP_FEE = 500;
    int24 internal constant SPACING = 10;
    uint32 internal constant FEE = 3_000_000; // 0.30%
    int256 internal constant UNIT = 2 ** 16;
    uint256 internal constant MAX_AMOUNT = type(uint128).max;
    BandGuardV2 internal guard;
    MockAnchorHook internal mock;
    PoolKey internal key;
    PoolId internal id;

    function setUp() public {
        guard = new BandGuardV2();
        mock = new MockAnchorHook();
        key = PoolKey(Currency.wrap(TOKEN0), Currency.wrap(TOKEN1), LP_FEE, SPACING, IHooks(address(mock)));
        id = key.toId();
    }

    function _pack(uint16 bandBps) internal view returns (bytes memory) {
        return abi.encodePacked(PM, TOKEN0, TOKEN1, LP_FEE, SPACING, address(mock), bandBps, uint16(300), uint8(0));
    }

    /// @dev The real guard on an EXACT-OUTPUT fill: `isExactIn` false, net input `net`, output `out`.
    function _guard(int24 snap, bool zeroIn, uint16 bandBps, uint256 net, uint256 out) internal returns (bool ok) {
        mock.set(id, snap, int56(int256(snap) * UNIT));
        SwapQuery memory q = SwapQuery(
            bytes32(uint256(1)), address(1), address(0xBEEF), zeroIn ? TOKEN0 : TOKEN1, zeroIn ? TOKEN1 : TOKEN0, false
        );
        SwapRegisters memory r = SwapRegisters(11, 22, net, out, 0);
        try guard.extruction(true, 0, q, r, _pack(bandBps), "") returns (uint256, uint256, SwapRegisters memory) {
            return true;
        } catch {
            return false;
        }
    }

    function _scale(int24 snap) internal pure returns (uint256 ref, uint256 shift) {
        uint256 s = TickMath.getSqrtPriceAtTick(snap);
        if (s < 2 ** 127) return (s * s, 192);
        return (FullMath.mulDiv(s, s, 2 ** 96), 96);
    }

    function _reserves(int24 snap, bool zeroIn, uint256 x) internal pure returns (uint256 y) {
        (uint256 ref, uint256 shift) = _scale(snap);
        y = zeroIn ? FullMath.mulDiv(x, ref, 2 ** shift) : FullMath.mulDiv(x, 2 ** shift, ref);
    }

    function _maker(uint256 x, uint256 y, uint32 fee) internal pure returns (MakerVenue.Maker memory m) {
        m.x = x;
        m.y = y;
        m.feeE9 = fee;
    }

    /// @dev Whether the real guard accepts an exact-output fill of `b` on `m`.
    function _outPasses(MakerVenue.Maker memory m, int24 snap, bool zeroIn, uint16 bps, uint256 b)
        internal
        returns (bool)
    {
        (uint256 net,) = MakerVenue.quoteExactOut(m, b);
        return _guard(snap, zeroIn, bps, net, b);
    }

    /// @dev Every fill the test can name in `[bMin, bMax]` passes the real guard: the first and last 150 integers, 100
    ///      evenly spaced and every power-of-two multiple of `bMin` (the small end, where the XYC ceiling costs most).
    function _density(MakerVenue.Maker memory m, int24 snap, bool zeroIn, uint16 bps, uint256 bMin, uint256 bMax)
        internal
    {
        assertGt(bMin, 0, "bMin is zero");
        assertLe(bMin, bMax, "bMin above bMax");
        for (uint256 b = bMin; b < bMin + 150 && b <= bMax; b++) {
            assertTrue(_outPasses(m, snap, zeroIn, bps, b), "b just above bMin fails");
        }
        for (uint256 b = bMax; b + 150 > bMax && b >= bMin; b--) {
            assertTrue(_outPasses(m, snap, zeroIn, bps, b), "b just below bMax fails");
            if (b == 0) break;
        }
        uint256 span = bMax - bMin;
        for (uint256 k; k <= 100; k++) {
            assertTrue(_outPasses(m, snap, zeroIn, bps, bMin + span * k / 100), "an evenly spaced b fails");
        }
        for (uint256 b = bMin; b <= bMax && b != 0; b *= 2) {
            assertTrue(_outPasses(m, snap, zeroIn, bps, b), "a power-of-two multiple of bMin fails");
        }
    }

    function _regimeXY(string memory name, int24 snap, bool zeroIn, uint256 x, uint256 y, uint16 bps) internal {
        (MakerVenue.Status st, uint256 bMin, uint256 bMax,) =
            MakerVenue.capsOut(x, y, FEE, y, type(uint256).max, snap, zeroIn, bps);
        assertEq(uint8(st), uint8(MakerVenue.Status.OK), string.concat(name, ": status"));
        _density(_maker(x, y, FEE), snap, zeroIn, bps, bMin, bMax);
        emit log_named_uint(string.concat(name, ": bps ", vm.toString(bps), " bMin / bMax relative 1e18"), bMin * 1e18 / bMax);
    }

    function _regime(string memory name, int24 snap, bool zeroIn, uint256 x, uint16 bps) internal {
        _regimeXY(name, snap, zeroIn, x, _reserves(snap, zeroIn, x), bps);
    }

    function _regimeSet(string memory name, int24 snap, uint256 x0, uint256 x1) internal {
        uint16[3] memory bpsList = [uint16(1), 200, 10_000];
        for (uint256 i; i < 3; i++) {
            _regime(string.concat(name, " token0 in"), snap, true, x0, bpsList[i]);
            _regime(string.concat(name, " token1 in"), snap, false, x1, bpsList[i]);
        }
    }

    function _pricedPair(int24 snap, bool zeroIn) internal pure returns (uint256 x, uint256 y) {
        (uint256 ref, uint256 shift) = _scale(snap);
        uint256 big = 1e36;
        bool token1Larger = snap >= 0;
        if (zeroIn) {
            if (token1Larger) {
                y = big;
                x = FullMath.mulDiv(y, 2 ** shift, ref);
            } else {
                x = big;
                y = FullMath.mulDiv(x, ref, 2 ** shift);
            }
        } else {
            if (token1Larger) {
                x = big;
                y = FullMath.mulDiv(x, 2 ** shift, ref);
            } else {
                y = big;
                x = FullMath.mulDiv(y, ref, 2 ** shift);
            }
        }
    }

    // ---------------------------------------------------------------- rounding

    /// @dev SwapVM's exact output: XYC input rounded UP (`XYCSwap.sol:28-31`), then the fee grossed up, rounded UP
    ///      (`Fee.sol:95`). Hand-computed: x = y = 1,000, b = 7, fee 0.30%: net = ceil(7000 / 993) = 8, gross = 8 +
    ///      ceil(8 * 3e6 / (1e9 - 3e6)) = 8 + 1 = 9.
    function test_V208_quoteExactOutRoundsUpTwice() public pure {
        MakerVenue.Maker memory m = MakerVenue.Maker(address(0), bytes32(0), MakerVenue.Status.OK, 1_000, 1_000, FEE, 0, 0, 0);
        (uint256 net, uint256 gross) = MakerVenue.quoteExactOut(m, 7);
        assertEq(net, 8, "net: ceil(7 * 1000 / 993)");
        assertEq(gross, 9, "gross: 8 + ceil(8 * fee / (1e9 - fee))");
        (net, gross) = MakerVenue.quoteExactOut(m, 1);
        assertEq(net, 2, "net: ceil(1000 / 999)");
        assertEq(gross, 3, "gross: 2 + ceil(2 * 3e6 / 997e6) = 3");
    }

    // ---------------------------------------------------------------- the cap against the real guard

    function test_V208_bandCapOutRegime6to18() public {
        _regimeSet("USDC<->MUMB", TICK_6_18_OUT, 100_000e6, 100_000e18);
    }

    function test_V208_bandCapOutRegimeThinMaker() public {
        _regimeSet("thin USDC<->MUMB", TICK_6_18_OUT, 1_000e6, 1_000e18);
    }

    function test_V208_bandCapOutRegime18x18AtTick0() public {
        _regimeSet("18/18 tick 0", 0, 100_000e18, 100_000e18);
    }

    function test_V208_bandCapOutRegimeX96AndExtremeTicks() public {
        int24[4] memory ticks = [int24(430_000), 600_000, -430_000, -600_000];
        for (uint256 i; i < 4; i++) {
            int24 snap = ticks[i];
            (, uint256 shift) = _scale(snap);
            assertEq(shift, snap > 0 ? 96 : 192, "the scale the guard uses at this tick");
            for (uint256 d; d < 2; d++) {
                bool zeroIn = d == 0;
                (uint256 x, uint256 y) = _pricedPair(snap, zeroIn);
                _regimeXY(
                    string.concat("tick ", vm.toString(int256(snap)), zeroIn ? " token0 in" : " token1 in"),
                    snap,
                    zeroIn,
                    x,
                    y,
                    200
                );
            }
        }
    }

    /// @dev Named risk: the exact-output band cap passes BandGuardV2 for every fill in its range. Random tick, band,
    ///      fee, size and start price inside the band, both directions; the range's ends, their neighbours and four
    ///      pseudo-random fills in between are fed to the real guard.
    function testFuzz_V208_bandCapOutPasses(
        int24 tickSeed,
        uint256 xSeed,
        uint16 bpsSeed,
        uint256 devSeed,
        uint32 feeSeed,
        bool zeroIn,
        uint256 pick
    ) public {
        int24 snap = int24(bound(int256(tickSeed), -300_000, 300_000));
        uint16 bps = uint16(bound(bpsSeed, 1, 10_000));
        uint32 fee = uint32(bound(feeSeed, 0, 500_000_000));
        uint256 x = bound(xSeed, 1e9, 1e30);
        uint256 s = TickMath.getSqrtPriceAtTick(snap);
        uint256 ref = s * s;
        uint256 d = bound(devSeed, 0, uint256(bps) / 2);
        uint256 factor = devSeed % 2 == 0 ? 10_000 + d : 10_000 - d;
        uint256 y = zeroIn
            ? FullMath.mulDiv(x, ref * factor, (2 ** 192) * 10_000)
            : FullMath.mulDiv(x, (2 ** 192) * 10_000, ref * factor);
        vm.assume(y >= 1e6 && y <= MAX_AMOUNT);
        (MakerVenue.Status st, uint256 bMin, uint256 bMax,) =
            MakerVenue.capsOut(x, y, fee, y, type(uint256).max, snap, zeroIn, bps);
        vm.assume(st == MakerVenue.Status.OK);
        assertGt(bMax, 0, "cap is zero");
        MakerVenue.Maker memory m = _maker(x, y, fee);
        uint256 span = bMax - bMin + 1;
        uint256[8] memory picks = [
            bMin,
            bMax,
            bMin + 1 > bMax ? bMax : bMin + 1,
            bMax - 1 < bMin ? bMin : bMax - 1,
            bMin + uint256(keccak256(abi.encode(pick, 0))) % span,
            bMin + uint256(keccak256(abi.encode(pick, 1))) % span,
            bMin + uint256(keccak256(abi.encode(pick, 2))) % span,
            bMin + uint256(keccak256(abi.encode(pick, 3))) % span
        ];
        for (uint256 i; i < 8; i++) {
            assertTrue(_outPasses(m, snap, zeroIn, bps, picks[i]), "a fill inside [bMin, bMax] is refused");
        }
    }
}

/// @notice V2-08: exact output through the hook on the mainnet fork.
/// @dev Same fixture and style as V2-07. Every comparison with pool-only uses a REAL pool-only exact-output swap on
///      the same snapshot, makers unregistered. Reference numbers are the `exactOut` vectors (V2-00).
contract V208ExactOutTest is SplitBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bool internal lastExactIn;
    int256 internal lastSpec;

    // =====================================================================================================
    // Helpers
    // =====================================================================================================

    /// @dev The taker data the hook sends with an exact-output leg: strict threshold `a` on the INPUT, output to the hook.
    function _tdOut(uint256 a) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: address(0),
                isExactIn: false,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: true,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: true,
                threshold: abi.encode(a),
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

    /// @dev SwapVM's exact-output input: XYC rounded up, then the fee grossed up, rounded up.
    function _grossOut(uint256 x, uint256 y, uint32 feeE9, uint256 b) internal pure returns (uint256) {
        uint256 net = Math.ceilDiv(b * x, y - b);
        return net + Math.ceilDiv(net * feeE9, 1e9 - feeE9);
    }

    /// @dev An exact-output swap of `b` through the trader's router; records the event's mode.
    function _runOut(PoolKey memory k, bool zfo, uint256 b) internal returns (Run memory r) {
        (address tIn, address tOut) = _io(k, zfo);
        uint256 inB = IERC20(tIn).balanceOf(trader);
        uint256 outB = IERC20(tOut).balanceOf(trader);
        vm.recordLogs();
        uint256 g = gasleft();
        _swap(k, trader, zfo, int256(b), "");
        r.gasUsed = g - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (r.legs, r.emitted) = _legsFrom(logs, address(hookV2));
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(hookV2) && logs[i].topics[0] == ConfluenceHook.ConfluenceSwap.selector) {
                (, lastExactIn, lastSpec,,,,,,) = abi.decode(
                    logs[i].data, (bool, bool, int256, int24, int24, uint160, uint128, uint24, ConfluenceHook.Leg[])
                );
            }
        }
        r.paid = inB - IERC20(tIn).balanceOf(trader);
        r.got = IERC20(tOut).balanceOf(trader) - outB;
    }

    /// @dev The same exact-output swap with every maker unregistered, from the current state; the state is restored.
    function _poolOnlyOut(PoolKey memory k, bool zfo, uint256 b) internal returns (Run memory r) {
        uint256 s = vm.snapshotState();
        _unregisterAll(k);
        r = _runOut(k, zfo, b);
        require(vm.revertToStateAndDelete(s), "revert failed");
    }

    function _planOut(PoolKey memory k, bool zfo, uint256 b) internal view returns (Plan memory) {
        (int24 s, int56 e,) = hookV2.anchorOfX(k.toId());
        return splitter.planExactOut(k, zfo, _lim(zfo), b, s, e);
    }

    /// @dev Exact books for an exact-output swap: the trader got `b`, paid `r.paid`; the PoolManager gave the pool's
    ///      share of the output and kept the pool's share of the input; each maker moved exactly its leg in wallet and
    ///      Aqua, each filled leg's input equals SwapVM's exact-output quote from the pre-swap balances; the hook holds
    ///      nothing and every allowance is 0.
    function _assertBooksOut(Book memory b0, Book memory b1, bool zfo, uint256 b, Run memory r, M[] memory ms)
        internal
        view
    {
        (uint256 iIn, uint256 iOut) = zfo ? (0, 1) : (1, 0);
        (uint256 sumIn, uint256 sumOut) = _sumLegs(r.legs);
        assertEq(r.got, b, "the trader got exactly the requested output");
        assertEq(b1.trader[iOut] - b0.trader[iOut], b, "trader output (books)");
        assertEq(b0.trader[iIn] - b1.trader[iIn], r.paid, "trader input (books)");
        assertEq(b0.pm[iOut] - b1.pm[iOut], b - sumOut, "the PoolManager gave the pool's share of the output");
        assertEq(b1.pm[iIn] - b0.pm[iIn], r.paid - sumIn, "the PoolManager kept the pool's share of the input");
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
                    l.amountIn,
                    _grossOut(b0.virt[j][iIn], b0.virt[j][iOut], ms[j].p.feeE9, l.amountOut),
                    "leg input = SwapVM's exact-output quote"
                );
            } else {
                assertEq(l.amountIn + l.amountOut, 0, "a skipped slot moves nothing");
            }
        }
        _assertClean();
    }

    function _vecCase(string memory name) internal view returns (Vectors.ExactOutCase memory c) {
        string memory json = Vectors.read(Vectors.V1_DEMO);
        uint256 n = Vectors.exactOutCount(json);
        for (uint256 i; i < n; i++) {
            c = Vectors.exactOut(json, i);
            if (keccak256(bytes(c.name)) == keccak256(bytes(name))) return c;
        }
        revert("no such exactOut vector");
    }

    /// @dev The makers of a vector case, registered with real funds (wallet = virtual) and the case's band.
    function _joinVec(Vectors.ExactOutCase memory c) internal returns (M[] memory ms) {
        ms = new M[](c.makers.length);
        bool usdcIn = c.zeroForOne; // USDC is currency0 in this fork
        for (uint256 j; j < c.makers.length; j++) {
            Vectors.VenueV memory v = c.makers[j];
            StrategyTemplate.Params memory p = _pf(v.feeE9);
            if (c.bandBps != 0) p.bandBps = uint16(c.bandBps);
            ms[j] = _joinM(keyV2, makers[j], usdcIn ? v.y : v.x, usdcIn ? v.x : v.y, p);
        }
    }

    /// @dev Output-side walk of the pool: the sum of its segments' `capOut`.
    function _walkedOut(PoolKey memory k, bool zfo) internal view returns (uint256 w) {
        PoolVenue.Pool memory p = PoolVenue.read(manager, k.toId(), k.tickSpacing, zfo, _lim(zfo));
        for (uint256 i; i < p.segments.length; i++) {
            w += p.segments[i].capOut;
        }
    }

    /// @dev Mocks the splitter's exact-output return and checks the swap is exact pool-only with `SKIP_PLAN` slots.
    function _expectPoolOnlyOut(
        bytes memory ret,
        bool zfo,
        uint256 b,
        Run memory po,
        M[] memory ms,
        string memory ctx
    ) internal {
        uint256 s = vm.snapshotState();
        vm.mockCall(address(splitter), abi.encodeWithSelector(splitter.planExactOut.selector), ret);
        Book memory b0 = _book(ms);
        Run memory r = _runOut(keyV2, zfo, b);
        _assertBooksOut(b0, _book(ms), zfo, b, r, ms);
        _expectAllStatus(r.legs, LegStatus.SKIP_PLAN, ctx);
        assertEq(r.paid, po.paid, string.concat(ctx, ": pool-only input"));
        vm.clearMockedCalls();
        vm.revertToState(s);
    }

    // =====================================================================================================
    // Spec acceptance
    // =====================================================================================================

    /// @dev Written first. `beforeSwap` returns `(specified, unspecified) = (-sum b, +sum a)` for exact output (v4:
    ///      `Hooks.sol:272-278` adds the specified part to `amountToSwap`; `CustomCurveHook.sol:46` returns
    ///      `(-amountSpecified, +amountSpecified)`). With the signs wrong the PoolManager does not net to zero and the
    ///      swap reverts; with them right the books close exactly. One maker, 990 MUMB out, USDC in: the legs, the
    ///      pool's leg and the trader's payment equal the V2-00 vector to the wei, and the event reports exact output.
    function test_V208_deltaSignsNet() public {
        Vectors.ExactOutCase memory c = _vecCase("usdc-in-priya");
        _initExact(keyV2);
        M[] memory ms = _joinVec(c);
        Book memory b0 = _book(ms);
        Run memory r = _runOut(keyV2, c.zeroForOne, c.amount);
        Book memory b1 = _book(ms);
        assertTrue(r.emitted, "exact output now emits ConfluenceSwap");
        assertFalse(lastExactIn, "the event reports exact output");
        assertEq(lastSpec, int256(c.amount), "the event carries amountSpecified = +B");
        assertEq(r.legs[0].status, LegStatus.FILLED, "the maker filled");
        assertEq(r.legs[0].amountOut, c.alloc[1], "leg output b_i = vector");
        assertEq(r.legs[0].amountIn, c.perVenue[1], "leg input a_i = vector");
        assertEq(r.paid, c.totalInt, "trader paid the vector's total to the wei");
        _assertBooksOut(b0, b1, c.zeroForOne, c.amount, r, ms);
    }

    /// @dev Both directions, one maker and three makers: legs, pool share and the trader's payment equal V2-00 to the
    ///      wei; the pool's share costs exactly what a REAL pool-only swap of that share costs.
    function test_V208_exactOutBothDirections() public {
        string[4] memory names = ["usdc-in-priya", "usdc-in-three", "mumb-in-priya", "mumb-in-three"];
        for (uint256 i; i < 4; i++) {
            uint256 s = vm.snapshotState();
            _checkVector(names[i]);
            vm.revertToState(s);
        }
    }

    function _checkVector(string memory name) internal {
        Vectors.ExactOutCase memory c = _vecCase(name);
        _initExact(keyV2);
        M[] memory ms = _joinVec(c);
        uint256 poolShareCost = _poolOnlyOut(keyV2, c.zeroForOne, c.alloc[0]).paid;
        Book memory b0 = _book(ms);
        Run memory r = _runOut(keyV2, c.zeroForOne, c.amount);
        Book memory b1 = _book(ms);
        assertTrue(r.emitted, name);
        uint256 sumIn;
        for (uint256 j; j < ms.length; j++) {
            assertEq(r.legs[j].status, LegStatus.FILLED, name);
            assertEq(r.legs[j].amountOut, c.alloc[j + 1], string.concat(name, ": b_i"));
            assertEq(r.legs[j].amountIn, c.perVenue[j + 1], string.concat(name, ": a_i"));
            sumIn += r.legs[j].amountIn;
        }
        assertEq(r.paid, c.totalInt, string.concat(name, ": total"));
        assertEq(r.paid, sumIn + poolShareCost, string.concat(name, ": legs + a real pool swap of the share"));
        assertLt(r.paid, c.poolOnlyIn, string.concat(name, ": cheaper than pool-only"));
        _assertBooksOut(b0, b1, c.zeroForOne, c.amount, r, ms);
    }

    /// @dev Named risk: the trader never pays more than pool-only for the same output, against a REAL pool-only swap,
    ///      in all eight vector cases. Where the optimum gives the makers nothing the swap IS pool-only. The
    ///      band-capped case is compared with the vector (which caps the maker at the real-number band edge E) with a
    ///      tolerance derived here, in wei, before the assertion:
    ///      the chain's cap b' is the safe cap, b' <= E. Moving E - b' more output to the pool costs at most
    ///      (E - b') * m, where m is the pool's marginal input per output unit at the end of its share. For a
    ///      constant-product pool, marginal / average = y / (y - s) with s the pool's output share and y its output
    ///      reserve, and s * 100 < y here (asserted), so m <= average * 101 / 100 = (pool leg input / pool leg output)
    ///      * 101 / 100. The maker's saving over the gap is not counted (it only lowers the true difference). Rounding:
    ///      one ceiling per maker step (two) and per pool step (one) in each of the two totals, 4 wei in all.
    ///      tolerance = (E - b') * poolIn * 101 / (poolOut * 100) + 4. It is computed from the case and never widened.
    function test_V208_minimisesInput() public {
        string[8] memory names = [
            "usdc-in-priya",
            "usdc-in-three",
            "usdc-in-band",
            "usdc-in-poolOptimal",
            "mumb-in-priya",
            "mumb-in-three",
            "mumb-in-band",
            "mumb-in-poolOptimal"
        ];
        for (uint256 i; i < 8; i++) {
            uint256 s = vm.snapshotState();
            _checkMinimises(names[i]);
            vm.revertToState(s);
        }
    }

    function _checkMinimises(string memory name) internal {
        Vectors.ExactOutCase memory c = _vecCase(name);
        _initExact(keyV2);
        M[] memory ms = _joinVec(c);
        Run memory po = _poolOnlyOut(keyV2, c.zeroForOne, c.amount);
        assertEq(po.paid, c.poolOnlyIn, string.concat(name, ": vector's pool-only = a real pool-only swap"));
        Book memory b0 = _book(ms);
        Run memory r = _runOut(keyV2, c.zeroForOne, c.amount);
        _assertBooksOut(b0, _book(ms), c.zeroForOne, c.amount, r, ms);
        assertLe(r.paid, po.paid, string.concat(name, ": never pays more than pool-only"));
        if (_endsWith(name, "poolOptimal")) {
            assertEq(r.paid, po.paid, "pool-only is optimal: the swap is pool-only");
            (uint256 sumIn,) = _sumLegs(r.legs);
            assertEq(sumIn, 0, "no leg");
        } else if (_endsWith(name, "band")) {
            _checkBandTolerance(name, c, r);
        } else {
            assertEq(r.paid, c.totalInt, string.concat(name, ": equals the vector to the wei"));
        }
    }

    function _checkBandTolerance(string memory name, Vectors.ExactOutCase memory c, Run memory r) internal view {
        uint256 edge = c.makers[0].cap; // the vector's cap: the real-number band edge, floored
        uint256 bChain = r.legs[0].amountOut;
        assertEq(r.legs[0].status, LegStatus.FILLED, "band case: filled at its cap");
        assertLe(bChain, edge, "the safe cap is inside the real-number edge");
        assertGt(bChain, 0, "the safe cap is not zero");
        PoolVenue.Pool memory pool =
            PoolVenue.read(manager, keyV2.toId(), keyV2.tickSpacing, c.zeroForOne, _lim(c.zeroForOne));
        assertLt(c.alloc[0] * 100, pool.segments[0].y, "premise: the pool's share is under 1% of its reserve");
        uint256 tol = (edge - bChain) * c.perVenue[0] * 101 / (c.alloc[0] * 100) + 4;
        console2.log(string.concat(name, ": edge - chain cap (output wei)"), edge - bChain);
        console2.log(string.concat(name, ": tolerance (input wei)"), tol);
        assertGe(r.paid + 4, c.totalInt, "band case: not cheaper than the vector beyond rounding");
        assertLe(r.paid, c.totalInt + tol, "band case: within the derived tolerance of the vector");
    }

    /// @dev A leg whose strict threshold is off by one either way is refused by the router and skipped, never
    ///      overcharged: the trader pays exactly what pool-only pays, the input is settled back.
    function test_V208_strictThreshold() public {
        string[2] memory names = ["usdc-in-priya", "mumb-in-priya"];
        for (uint256 i; i < 2; i++) {
            for (uint256 dir; dir < 2; dir++) {
                uint256 s = vm.snapshotState();
                _checkStrict(names[i], dir == 0);
                vm.revertToState(s);
            }
        }
    }

    function _checkStrict(string memory name, bool below) internal {
        Vectors.ExactOutCase memory c = _vecCase(name);
        _initExact(keyV2);
        M[] memory ms = _joinVec(c);
        Run memory po = _poolOnlyOut(keyV2, c.zeroForOne, c.amount);
        Plan memory q = _copy(_planOut(keyV2, c.zeroForOne, c.amount));
        assertGt(q.amountIn[0], 0, "premise: a leg is planned");
        q.amountIn[0] = below ? q.amountIn[0] - 1 : q.amountIn[0] + 1; // the router needs exactly a_i
        vm.mockCall(address(splitter), abi.encodeWithSelector(splitter.planExactOut.selector), abi.encode(q));
        Book memory b0 = _book(ms);
        Run memory r = _runOut(keyV2, c.zeroForOne, c.amount);
        _assertBooksOut(b0, _book(ms), c.zeroForOne, c.amount, r, ms);
        assertEq(r.legs[0].status, LegStatus.SKIP_REVERT, "the strict threshold refuses the leg");
        assertEq(r.paid, po.paid, "skipped, not overcharged: the pool fills everything");
        vm.clearMockedCalls();
    }

    /// @dev One maker's router call reverts: that leg is skipped, the pool fills its share, the others fill, the
    ///      trader still gets exactly B and pays the other legs plus a REAL pool swap of the larger share.
    function test_V208_legFailureFallsBack() public {
        Vectors.ExactOutCase memory c = _vecCase("usdc-in-three");
        _initExact(keyV2);
        M[] memory ms = _joinVec(c);
        uint256 poolShareCost = _poolOnlyOut(keyV2, true, c.alloc[0] + c.alloc[2]).paid;
        uint256 poolOnlyPaid = _poolOnlyOut(keyV2, true, c.amount).paid;
        _mockOutRevert(ms[1], true, c.alloc[2], c.perVenue[2]);
        Book memory bk0 = _book(ms);
        Run memory r = _runOut(keyV2, true, c.amount);
        _assertBooksOut(bk0, _book(ms), true, c.amount, r, ms);
        assertEq(r.legs[0].status, LegStatus.FILLED, "maker 0 fills");
        assertEq(r.legs[1].status, LegStatus.SKIP_REVERT, "maker 1's call reverted: SKIP_REVERT");
        assertEq(r.legs[2].status, LegStatus.FILLED, "maker 2 fills");
        assertEq(r.legs[0].amountOut, c.alloc[1], "leg 0 output");
        assertEq(r.legs[2].amountOut, c.alloc[3], "leg 2 output");
        assertEq(r.paid, c.perVenue[1] + c.perVenue[3] + poolShareCost, "legs + a real pool swap of the larger share");
        assertLe(r.paid, poolOnlyPaid, "still never worse than pool-only");
    }

    /// @dev The router call the hook makes for `m`'s exact-output leg (output `b`, strict input `a`) reverts.
    function _mockOutRevert(M memory m, bool zfo, uint256 b, uint256 a) internal {
        (address tIn, address tOut) = _io(keyV2, zfo);
        ISwapVM.Order memory o = _order(keyV2, m);
        vm.mockCallRevert(ROUTER, abi.encodeCall(ISwapVM.swap, (o, tIn, tOut, b, _tdOut(a))), abi.encode("mocked revert"));
    }

    /// @dev The hook holds nothing and every allowance is 0 after exact-output swaps in both directions, with fills
    ///      and with a failed leg.
    function test_V208_hookHoldsNothing() public {
        for (uint256 d; d < 2; d++) {
            bool zfo = d == 0;
            Vectors.ExactOutCase memory c = _vecCase(zfo ? "usdc-in-three" : "mumb-in-three");
            uint256 s = vm.snapshotState();
            _initExact(keyV2);
            M[] memory ms = _joinVec(c);
            Book memory b0 = _book(ms);
            Run memory r = _runOut(keyV2, zfo, c.amount);
            _assertBooksOut(b0, _book(ms), zfo, c.amount, r, ms);
            assertEq(_countStatus(r.legs, LegStatus.FILLED), 3, "three legs");
            vm.revertToState(s);
        }
        // A failed leg leaves the hook clean too.
        Vectors.ExactOutCase memory c2 = _vecCase("mumb-in-three");
        _initExact(keyV2);
        M[] memory ms2 = _joinVec(c2);
        _mockOutRevert(ms2[0], false, c2.alloc[1], c2.perVenue[1]);
        Book memory bk0 = _book(ms2);
        Run memory r2 = _runOut(keyV2, false, c2.amount);
        _assertBooksOut(bk0, _book(ms2), false, c2.amount, r2, ms2);
        assertEq(r2.legs[0].status, LegStatus.SKIP_REVERT, "the mocked leg failed");
    }

    // =====================================================================================================
    // Named risks
    // =====================================================================================================

    /// @dev The exact-output quote equals the router's own quote and a real fill, to the wei, in both directions, for
    ///      5 sizes from the smallest fill the guard accepts to the cap. The taker is the hook's address (the strategy
    ///      is exclusive): funded and pranked, as V2-05's Unichain test does.
    function test_V208_quoteEqualsFill() public {
        for (uint256 d; d < 2; d++) {
            uint256 s = vm.snapshotState();
            _quoteEqualsFillDir(d == 0);
            vm.revertToState(s);
        }
    }

    function _quoteEqualsFillDir(bool zfo) internal {
        _initExact(keyV2);
        M[] memory ms = new M[](1);
        ms[0] = _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
        MakerVenue.Maker memory m = _readOutVenue(ms[0], zfo);
        assertEq(uint8(m.status), uint8(MakerVenue.Status.OK), "premise: the maker is live");
        uint256 bMax = m.capOut;
        uint256[5] memory sizes =
            [m.capMin, bMax / 1000 > m.capMin ? bMax / 1000 : m.capMin + 1, bMax / 10, bMax / 2, bMax];
        for (uint256 i; i < 5; i++) {
            uint256 snapshot = vm.snapshotState();
            _quoteEqualsFillOne(ms, m, zfo, sizes[i]);
            vm.revertToState(snapshot);
        }
    }

    function _readOutVenue(M memory maker, bool zfo) internal view returns (MakerVenue.Maker memory) {
        (int24 snap, int56 emaX,) = hookV2.anchorOfX(keyV2.toId());
        MakerVenue.Entry[] memory e = new MakerVenue.Entry[](1);
        e[0] = MakerVenue.Entry(maker.who, maker.p, maker.hash);
        return MakerVenue.readOut(manager, keyV2, _guard(), e, zfo, snap, emaX)[0];
    }

    function _quoteEqualsFillOne(M[] memory ms, MakerVenue.Maker memory m, bool zfo, uint256 b) internal {
        (address tIn, address tOut) = _io(keyV2, zfo);
        uint256 want = _grossOut(m.x, m.y, m.feeE9, b);
        (, uint256 gross) = MakerVenue.quoteExactOut(m, b);
        assertEq(gross, want, "the library's quote = SwapVM's formula");
        ISwapVM.Order memory order = _order(keyV2, ms[0]); // built before the prank: it calls the hook
        bytes memory td = _tdOut(want);
        vm.prank(address(hookV2));
        (uint256 qIn, uint256 qOut,) = ISwapVM(ROUTER).quote(order, tIn, tOut, b, td);
        assertEq(qIn, want, "router quote: input");
        assertEq(qOut, b, "router quote: output");
        // A real fill.
        deal(tIn, address(hookV2), want);
        Book memory b0 = _book(ms);
        vm.startPrank(address(hookV2));
        IERC20(tIn).approve(ROUTER, want);
        (uint256 fIn, uint256 fOut,) = ISwapVM(ROUTER).swap(order, tIn, tOut, b, td);
        vm.stopPrank();
        Book memory b1 = _book(ms);
        (uint256 iIn, uint256 iOut) = zfo ? (0, 1) : (1, 0);
        assertEq(fIn, want, "fill: input");
        assertEq(fOut, b, "fill: output");
        assertEq(b1.wallet[0][iIn], b0.wallet[0][iIn] + want, "maker wallet in");
        assertEq(b1.wallet[0][iOut], b0.wallet[0][iOut] - b, "maker wallet out");
        assertEq(b1.virt[0][iIn], b0.virt[0][iIn] + want, "maker Aqua in");
        assertEq(b1.virt[0][iOut], b0.virt[0][iOut] - b, "maker Aqua out");
        assertEq(IERC20(tOut).balanceOf(address(hookV2)), b, "the hook received the output");
        assertEq(IERC20(tIn).balanceOf(address(hookV2)), 0, "the hook's input was all pulled");
        assertEq(IERC20(tIn).allowance(address(hookV2), ROUTER), 0, "allowance used up");
    }

    /// @dev Carry-over: a pool short of B stays pool-only, even when makers could cover the rest. The plan is
    ///      `SKIP_NOT_BETTER` and the swap equals a real pool-only swap (a partial fill), exactly.
    function test_V208_hardEndPoolShortIsPoolOnly() public {
        _initExact(keyV2);
        M[] memory ms = new M[](1);
        ms[0] = _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
        uint256 b = 3_000 * MUMB_1; // the seed pool holds about 2,500 MUMB
        Run memory po = _poolOnlyOut(keyV2, true, b);
        assertLt(po.got, b, "premise: pool-only cannot give B");
        Book memory b0 = _book(ms);
        Run memory r = _runOut(keyV2, true, b);
        Book memory b1 = _book(ms);
        assertEq(r.got, po.got, "same output as pool-only");
        assertEq(r.paid, po.paid, "same input as pool-only");
        assertEq(r.legs[0].status, LegStatus.SKIP_NOT_BETTER, "the plan is pool-only");
        assertEq(b1.wallet[0][0], b0.wallet[0][0], "the maker moved nothing");
        _assertClean();
    }

    /// @dev The hook's own checks on an exact-output plan (D-36): every forged plan is `SKIP_PLAN` on every slot and
    ///      the swap is exactly pool-only.
    function test_V208_forgedPlansArePoolOnly() public {
        Vectors.ExactOutCase memory c = _vecCase("usdc-in-three");
        _initExact(keyV2);
        M[] memory ms = _joinVec(c);
        Run memory po = _poolOnlyOut(keyV2, true, c.amount);
        Plan memory p = _planOut(keyV2, true, c.amount);
        assertEq(_countFilled(p), 3, "premise: three legs planned");

        Plan memory q = _copy(p);
        q.amountOut[0] = p.capIn[0] + 1; // over the maker's reported cap
        q.poolIn = c.amount - q.amountOut[0] - q.amountOut[1] - q.amountOut[2];
        _expectPoolOnlyOut(abi.encode(q), true, c.amount, po, ms, "over cap");

        q = _copy(p);
        q.amountOut[0] = p.capMin[0] - 1; // under the smallest fill
        q.poolIn = c.amount - q.amountOut[0] - q.amountOut[1] - q.amountOut[2];
        _expectPoolOnlyOut(abi.encode(q), true, c.amount, po, ms, "under capMin");

        q = _copy(p);
        q.poolIn += 1; // the parts do not sum to B
        _expectPoolOnlyOut(abi.encode(q), true, c.amount, po, ms, "sum");

        q = _copy(p);
        q.status[0] = LegStatus.MAX_CODE + 1; // an invalid status
        _expectPoolOnlyOut(abi.encode(q), true, c.amount, po, ms, "bad status");

        q = _copy(p);
        q.amountOut[4] = p.amountOut[0]; // a leg for a slot that is not registered
        q.poolIn -= p.amountOut[0];
        _expectPoolOnlyOut(abi.encode(q), true, c.amount, po, ms, "nonexistent slot");

        q = _copy(p);
        q.amountIn[0] = uint256(type(uint128).max); // an input beyond int128
        _expectPoolOnlyOut(abi.encode(q), true, c.amount, po, ms, "input over int128");

        q = _copy(p);
        q.amountIn[0] = IERC20(USDC).balanceOf(address(manager)) + 1; // more input than the PoolManager holds
        _expectPoolOnlyOut(abi.encode(q), true, c.amount, po, ms, "PoolManager total");

        q = _copy(p);
        q.poolOnlyOut = 1; // pool-only claimed to cost almost nothing: the split is not better
        q.tail = 0;
        _expectPoolOnlyOut(abi.encode(q), true, c.amount, po, ms, "not better");

        q = _copy(p);
        (q.truncated, q.walked) = (1, 0); // the pool's share past a truncated walk
        _expectPoolOnlyOut(abi.encode(q), true, c.amount, po, ms, "truncated walk");

        _expectPoolOnlyOut("garbage", true, c.amount, po, ms, "wrong length");
    }

    function _countFilled(Plan memory p) internal pure returns (uint256 n) {
        for (uint256 i; i < 6; i++) {
            if (p.amountOut[i] > 0) n++;
        }
    }

    function _endsWith(string memory s, string memory suffix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(suffix);
        if (b.length > a.length) return false;
        for (uint256 i; i < b.length; i++) {
            if (a[a.length - b.length + i] != b[i]) return false;
        }
        return true;
    }

    // =====================================================================================================
    // Never worse (fuzz and coverage)
    // =====================================================================================================

    /// @dev Returns 0 if a leg filled, 1 if the plan fell back as not better, 2 if nothing was planned, 3 if the pool
    ///      was short of B (pool-only, a partial fill). `thin` is the coverage-only generator (as V2-07).
    function _neverWorseOutCase(uint256 seed, bool zfo, uint256 amountRaw, uint8 nRaw, bool gap, bool thin)
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
        uint256 unit = zfo ? MUMB_1 : USDC_1; // the OUTPUT token's unit
        uint256 b = thin ? _walkedOut(k, zfo) + bound(amountRaw, 1, 300) * unit : bound(amountRaw, 1, 3_000 * unit);
        Run memory po = _poolOnlyOut(k, zfo, b);
        Run memory r = _runOut(k, zfo, b);
        if (po.got < b) {
            assertEq(r.got, po.got, "pool short of B: exactly pool-only (output)");
            assertEq(r.paid, po.paid, "pool short of B: exactly pool-only (input)");
        } else {
            assertEq(r.got, b, "the trader gets exactly B");
            assertLe(r.paid, po.paid, "never pays more than the real pool-only swap");
        }
        (uint256 sumIn,) = _sumLegs(r.legs);
        if (sumIn == 0) assertEq(r.paid, po.paid, "no leg: exactly pool-only");
        assertEq(IERC20(USDC).balanceOf(address(hookV2)) + mumb.balanceOf(address(hookV2)), 0, "hook holds nothing");
        if (po.got < b) return 3;
        if (sumIn > 0) return 0;
        return _countStatus(r.legs, LegStatus.SKIP_NOT_BETTER) > 0 ? 1 : 2;
    }

    /// @dev Named risk: the trader never pays more input than pool-only for the same output, against a real pool-only
    ///      swap, over pool shape (v1 or truncated 8-segment), direction, amount (including past the pool's capacity)
    ///      and 0-6 makers in band.
    function testFuzz_V208_neverWorseThanPoolOnly(uint256 seed, bool zfo, uint256 amountRaw, uint8 nRaw, bool gap)
        public
    {
        _neverWorseOutCase(seed, zfo, amountRaw, nRaw, gap, false);
    }

    /// @dev The fuzz body over fixed seeds, counting what it covered; each category must occur.
    function test_V208_neverWorseCoverage() public {
        uint256[5] memory seen; // filled, not better, none planned, pool short, truncated shape
        for (uint256 i; i < COVERAGE_SEEDS; i++) {
            uint256 s = vm.snapshotState();
            uint256 h = uint256(keccak256(abi.encode("coverage-out", i)));
            bool thin = i >= COVERAGE_WIDE_SEEDS;
            bool gap = thin || (h >> 24) % 3 == 0;
            uint8 cat = _neverWorseOutCase(h, h % 2 == 0, h >> 8, uint8(h >> 16), gap, thin);
            if (cat == 3) seen[3]++;
            else seen[cat]++;
            if (gap) seen[4]++;
            vm.revertToState(s);
        }
        console2.log("coverage: some leg filled        ", seen[0]);
        console2.log("coverage: SKIP_NOT_BETTER         ", seen[1]);
        console2.log("coverage: nothing planned          ", seen[2]);
        console2.log("coverage: pool short of B          ", seen[3]);
        console2.log("coverage: truncated-walk pool      ", seen[4]);
        assertGt(seen[0], 0, "coverage: fills");
        assertGt(seen[1], 0, "coverage: not-better fallback");
        assertGt(seen[2], 0, "coverage: nothing planned");
        assertGt(seen[3], 0, "coverage: pool short");
        assertGt(seen[4], 0, "coverage: truncated shape");
    }

    // =====================================================================================================
    // Exact input unchanged (M3 and gas)
    // =====================================================================================================

    uint256 internal constant V207_GAS_POOL_ONLY = 239_925;
    uint256 internal constant V207_GAS_1 = 652_178;
    uint256 internal constant V207_GAS_3 = 1_101_719;
    uint256 internal constant V207_GAS_6 = 1_358_228;

    function _gasLine(string memory label, uint256 now_, uint256 v207) internal pure {
        int256 d = int256(now_) - int256(v207);
        console2.log(label, now_);
        console2.log("   V2-07 figure", v207);
        console2.log("   change (signed)", d);
    }

    /// @dev Exact input is untouched: the M3 number is still exactly 991549859869719173233 wei for 1,000 USDC with
    ///      empty `hookData`, and the swap gas (pool-only, 1, 3, 6 makers; V2-07's `gasLog` method) is reported next
    ///      to V2-07's figures. A change in gas is explained in D-36, not asserted away.
    function test_V208_exactInUnchanged() public {
        string memory json = Vectors.read(Vectors.V1_DEMO);
        Vectors.V1Case memory c = Vectors.v1Case(json, 0);
        _initExact(keyV2);
        uint256 s = vm.snapshotState();
        M[] memory one = new M[](1);
        one[0] = _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
        Run memory m3 = _run(keyV2, true, c.amount, "");
        assertEq(m3.got, 991549859869719173233, "M3: exactly 991549859869719173233 wei MUMB");
        assertEq(m3.got, c.totalInt, "M3: equals V2-00's closed form to the wei");
        assertTrue(m3.emitted, "exact input still emits");
        vm.revertToState(s);

        uint256 g0 = _coldRun(keyV2, true, 1_000 * USDC_1).gasUsed;
        one[0] = _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
        uint256 g1 = _coldRun(keyV2, true, 1_000 * USDC_1).gasUsed;
        vm.revertToState(s);
        _threeMakers();
        uint256 g3 = _coldRun(keyV2, true, 1_000 * USDC_1).gasUsed;
        _joinM(keyV2, makers[3], 50_000e18, 50_000e6, _p());
        _joinM(keyV2, makers[4], 1_000e18, 1_000e6, _p());
        _joinM(keyV2, makers[5], 30_000e18, 30_000e6, _pf(FEE_100));
        uint256 g6 = _coldRun(keyV2, true, 1_000 * USDC_1).gasUsed;
        _gasLine("gas exact-in: pool-only (no makers)", g0, V207_GAS_POOL_ONLY);
        _gasLine("gas exact-in: 1 maker", g1, V207_GAS_1);
        _gasLine("gas exact-in: 3 makers", g3, V207_GAS_3);
        _gasLine("gas exact-in: 6 makers", g6, V207_GAS_6);
    }

    // =====================================================================================================
    // Gas
    // =====================================================================================================

    /// @dev Worst-case `planExactOut` (6 makers, the 8-segment truncated pool, both directions, cold) stays under
    ///      `PLAN_GAS_CAP`; the number is reported next to `planExactIn`'s on the same state (V2-07 measured 838,822
    ///      for exact input, MUMB in).
    function test_V208_planGasUnderCap() public {
        PoolKey memory k = _gapKey();
        _initExact(k);
        (int24 snap,,) = hookV2.anchorOf(k.toId());
        for (uint256 i; i < 6; i++) {
            uint256 usdcRaw = (1_000 + 20_000 * i) * USDC_1;
            _joinM(k, makers[i], _mumbAt(usdcRaw, snap), usdcRaw, _pf(uint32(500_000 + 1_000_000 * i)));
        }
        (int24 sn, int56 em,) = hookV2.anchorOfX(k.toId());
        uint256 cap = hookV2.PLAN_GAS_CAP();
        for (uint256 d; d < 2; d++) {
            bool zfo = d == 0;
            uint256 walkedIn = _walked(k, zfo);
            uint256 walkedOut = _walkedOut(k, zfo);
            assertGt(PoolVenue.read(manager, k.toId(), k.tickSpacing, zfo, _lim(zfo)).segments.length, 7, "8 segments");
            _coolAll();
            uint256 g = gasleft();
            splitter.planExactIn(k, zfo, _lim(zfo), walkedIn, sn, em);
            uint256 gIn = g - gasleft();
            _coolAll();
            g = gasleft();
            splitter.planExactOut(k, zfo, _lim(zfo), walkedOut, sn, em);
            uint256 gOut = g - gasleft();
            console2.log(zfo ? "plan gas, token0 in: exact in " : "plan gas, token1 in: exact in ", gIn);
            console2.log(zfo ? "plan gas, token0 in: exact out" : "plan gas, token1 in: exact out", gOut);
            console2.log("PLAN_GAS_CAP", cap);
            assertLt(gOut, cap, "planExactOut is under PLAN_GAS_CAP");
            assertLt(gIn, cap, "planExactIn is under PLAN_GAS_CAP");
        }
    }

    function _coolAll() internal {
        address[8] memory touched =
            [address(manager), address(hookV2), address(splitter), AQUA, ROUTER, USDC, address(mumb), _guard()];
        for (uint256 i; i < touched.length; i++) {
            vm.cool(touched[i]);
        }
        for (uint256 i; i < 6; i++) {
            vm.cool(makers[i]);
        }
    }

    /// @dev The largest exact-output router fill (a maker with reserves near the envelope, filled at its cap) costs
    ///      less than `LEG_GAS_CAP`, both directions, cold: the gas of the router call itself.
    function test_V208_largestFillUnderLegGasCap() public {
        for (uint256 d; d < 2; d++) {
            uint256 s = vm.snapshotState();
            _largestFill(d == 0);
            vm.revertToState(s);
        }
    }

    function _largestFill(bool zfo) internal {
        _initExact(keyV2);
        M[] memory ms = new M[](1);
        ms[0] = _joinM(keyV2, makers[0], 1_000_000e18, 1_000_000e6, _p());
        MakerVenue.Maker memory m = _readOutVenue(ms[0], zfo);
        assertEq(uint8(m.status), uint8(MakerVenue.Status.OK), "premise: live");
        uint256 a = _grossOut(m.x, m.y, m.feeE9, m.capOut);
        (address tIn, address tOut) = _io(keyV2, zfo);
        deal(tIn, address(hookV2), a);
        vm.prank(address(hookV2));
        IERC20(tIn).approve(ROUTER, a);
        ISwapVM.Order memory order = _order(keyV2, ms[0]); // built before the prank: it calls the hook
        bytes memory td = _tdOut(a);
        _coolAll();
        vm.prank(address(hookV2));
        uint256 g = gasleft();
        ISwapVM(ROUTER).swap(order, tIn, tOut, m.capOut, td);
        uint256 used = g - gasleft();
        console2.log(zfo ? "largest exact-out fill gas, token0 in" : "largest exact-out fill gas, token1 in", used);
        console2.log("LEG_GAS_CAP", hookV2.LEG_GAS_CAP());
        assertLt(used, hookV2.LEG_GAS_CAP(), "a fill is under LEG_GAS_CAP");
    }

    /// @dev D-20's sweep on an exact-output swap (990 MUMB out, three makers): at every gas limit where the pool-only
    ///      swap passes, the split swap passes, for legitimate legs and with the guard etched to burn every leg's cap.
    function test_V208_gasReserveAdequateExactOut() public {
        _initExact(keyV2);
        _threeMakers();
        uint256 filled = _sweepOut("legit");
        assertGt(filled, 0, "some limit fills a leg");
        vm.etch(_guard(), _burnerCode());
        _sweepOut("burning guard");
    }

    function _sweepOut(string memory label) internal returns (uint256 filled) {
        uint256 n = (500_000 - 285_000) / 5_000 + 1;
        uint256[] memory limits = new uint256[](n + 10);
        for (uint256 i; i < n; i++) {
            limits[i] = 285_000 + i * 5_000;
        }
        uint256[10] memory high =
            [uint256(550_000), 600_000, 700_000, 800_000, 1_000_000, 1_500_000, 2_000_000, 3_000_000, 4_000_000, 6_000_000];
        for (uint256 i; i < 10; i++) {
            limits[n + i] = high[i];
        }
        uint256 checked;
        for (uint256 i; i < limits.length; i++) {
            uint256 s = vm.snapshotState();
            _unregisterAll(keyV2);
            bool poolOk = _tryAtLimitOut(limits[i]);
            vm.revertToState(s);
            if (!poolOk) continue;
            checked++;
            vm.recordLogs();
            bool ok = _tryAtLimitOut(limits[i]);
            assertTrue(ok, string.concat(label, ": exact-out split swap reverted at gas limit ", vm.toString(limits[i])));
            (ConfluenceHook.Leg[] memory legs,) = _legsFrom(vm.getRecordedLogs(), address(hookV2));
            if (_countStatus(legs, LegStatus.FILLED) > 0) filled++;
            _assertClean();
            vm.revertToState(s);
        }
        assertGe(checked, 50, string.concat(label, ": precondition: the pool alone passes at (nearly) every limit"));
    }

    function _tryAtLimitOut(uint256 limit) internal returns (bool ok) {
        vm.startPrank(trader);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        try swapRouter.swap{gas: limit}(
            keyV2,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: int256(990 * MUMB_1), sqrtPriceLimitX96: _lim(true)
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
