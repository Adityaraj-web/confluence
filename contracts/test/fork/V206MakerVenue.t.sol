// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BandGuardV2, AnchorDrift, BandExceeded, BandNotComputed} from "../../src/BandGuardV2.sol";
import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {MakerVenue} from "../../src/libraries/MakerVenue.sol";
import {SplitMath} from "../../src/libraries/SplitMath.sol";
import {StrategyTemplate} from "../../src/libraries/StrategyTemplate.sol";
import {RegistryBase} from "../base/RegistryBase.t.sol";
import {TakerHelper} from "../base/TakerHelper.sol";
import {MockAnchorHook} from "../unit/V204BandGuard.t.sol";

/// @dev External wrappers around the internal library, so the fork tests call it as a separate contract would.
contract MakerVenueHarness {
    function read(
        IPoolManager manager,
        PoolKey calldata key,
        address guard,
        MakerVenue.Entry[] calldata entries,
        bool zeroForOne,
        int24 snapTick,
        int56 emaTickX
    ) external view returns (MakerVenue.Maker[] memory) {
        return MakerVenue.read(manager, key, guard, entries, zeroForOne, snapTick, emaTickX);
    }

    function quoteExactIn(MakerVenue.Maker calldata m, uint256 a) external pure returns (uint256, uint256) {
        return MakerVenue.quoteExactIn(m, a);
    }

    function real(address token, address maker, uint256 virtualBalance) external view returns (uint256) {
        return MakerVenue.real(token, maker, virtualBalance);
    }

    function toVenues(MakerVenue.Maker[] calldata ms)
        external
        pure
        returns (SplitMath.Venue[] memory, uint256[] memory)
    {
        return MakerVenue.toVenues(ms);
    }

    function maxMakers() external pure returns (uint256) {
        return MakerVenue.MAX_MAKERS;
    }

    function aqua() external pure returns (address) {
        return MakerVenue.AQUA;
    }

    function router() external pure returns (address) {
        return MakerVenue.ROUTER;
    }
}

/// @notice V2-06 maths, no fork: the caps and the mirrors of the guard, against the real `BandGuardV2`.
contract V206MakerVenueMathTest is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant PM = address(0x9999);
    address internal constant TOKEN0 = address(0x1000);
    address internal constant TOKEN1 = address(0x2000);
    uint24 internal constant LP_FEE = 500;
    int24 internal constant SPACING = 10;
    uint32 internal constant FEE = 3_000_000; // 0.30%
    int256 internal constant UNIT = 2 ** 16;
    uint256 internal constant MAX_AMOUNT = type(uint128).max;
    /// @dev tick of 1 USDC (6 decimals) = 1 MUMB (18 decimals) in the fork pool: price 1e12 currency1 per currency0.
    int24 internal constant TICK_6_18 = 276324;

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

    // ---------------------------------------------------------------- helpers

    function _setAnchor(int24 snap, int56 emaX) internal {
        mock.set(id, snap, emaX);
    }

    function _pack(uint16 bandBps, uint16 driftTicks) internal view returns (bytes memory) {
        return abi.encodePacked(PM, TOKEN0, TOKEN1, LP_FEE, SPACING, address(mock), bandBps, driftTicks, uint8(0));
    }

    /// @dev The real guard on a fill with net input `net` and output `out`: whether it passes and the revert selector.
    function _guard(int24 snap, int56 emaX, bool zeroIn, uint16 bandBps, uint16 driftTicks, uint256 net, uint256 out)
        internal
        returns (bool ok, bytes4 sel)
    {
        _setAnchor(snap, emaX);
        SwapQuery memory q = SwapQuery(
            bytes32(uint256(1)), address(1), address(0xBEEF), zeroIn ? TOKEN0 : TOKEN1, zeroIn ? TOKEN1 : TOKEN0, true
        );
        SwapRegisters memory r = SwapRegisters(11, 22, net, out, 0);
        try guard.extruction(true, 0, q, r, _pack(bandBps, driftTicks), "") returns (
            uint256, uint256, SwapRegisters memory
        ) {
            return (true, bytes4(0));
        } catch (bytes memory reason) {
            return (false, bytes4(reason));
        }
    }

    function _flat(int24 snap) internal pure returns (int56) {
        return int56(int256(snap) * UNIT);
    }

    /// @dev Reserves of a maker priced exactly at the snapshot: x of the input token, y = x * price (zeroIn) or
    ///      x / price (token1 in).
    function _reserves(int24 snap, bool zeroIn, uint256 x) internal pure returns (uint256 y) {
        uint256 s = TickMath.getSqrtPriceAtTick(snap);
        uint256 ref = s * s; // X192; the ticks used here sit below sqrt 2^127
        y = zeroIn ? FullMath.mulDiv(x, ref, 2 ** 192) : FullMath.mulDiv(x, 2 ** 192, ref);
    }

    function _maker(uint256 x, uint256 y, uint32 fee, uint256 capIn, uint256 capMin)
        internal
        pure
        returns (MakerVenue.Maker memory m)
    {
        m.x = x;
        m.y = y;
        m.feeE9 = fee;
        m.capIn = capIn;
        m.capMin = capMin;
    }

    /// @dev Largest gross input whose output is at most `b` (the output is nondecreasing in the input).
    function _maxGrossWithOut(MakerVenue.Maker memory m, uint256 b) internal pure returns (uint256 lo) {
        uint256 hi = MAX_AMOUNT;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo + 1) / 2;
            (, uint256 o) = MakerVenue.quoteExactIn(m, mid);
            if (o <= b) lo = mid;
            else hi = mid - 1;
        }
    }

    /// @dev Whether the real guard accepts a fill of gross input `a` on `m` at this anchor and band.
    function _fillPasses(MakerVenue.Maker memory m, int24 snap, bool zeroIn, uint16 bandBps, uint256 a)
        internal
        returns (bool ok)
    {
        (uint256 net, uint256 out) = MakerVenue.quoteExactIn(m, a);
        (ok,) = _guard(snap, _flat(snap), zeroIn, bandBps, 300, net, out);
    }

    // ---------------------------------------------------------------- rounding (named risk 1)

    function test_V206_quoteRoundsFeeUpThenOutputDown() public pure {
        // fee 0.30% of 1_000_001 = 3000.003 -> 3001 (ceil): net 997_000 (the floor of 1_000_001 * 0.997 = 997_000.997).
        MakerVenue.Maker memory m = _maker(1_000_000, 2_000_000, FEE, 0, 0);
        (uint256 net, uint256 out) = MakerVenue.quoteExactIn(m, 1_000_001);
        assertEq(net, 997_000, "net: fee rounded up");
        // out = floor(997000 * 2_000_000 / (1_000_000 + 997_000)) = floor(998_497_746_619.9 / ...) computed by hand:
        assertEq(out, uint256(997_000) * 2_000_000 / 1_997_000, "out: floor");
        // fee 0: net = a; a zero fill gives zero.
        m.feeE9 = 0;
        (net, out) = MakerVenue.quoteExactIn(m, 5);
        assertEq(net, 5);
        (net, out) = MakerVenue.quoteExactIn(m, 0);
        assertEq(net, 0);
        assertEq(out, 0);
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_V206_capInversionIsTight(uint256 xSeed, uint256 ySeed, uint256 oSeed, uint32 feeSeed)
        public
        view
    {
        // bandBps 10000 with the token0-in direction has no lower band edge (ref - lim = 0), so the output cap is the
        // only binding one; the maker is priced at the snapshot (tick 0, ref 1.0) so the start check passes.
        uint256 x = bound(xSeed, 1e6, 1e30);
        uint256 y = bound(ySeed, x / 2 + 1, x * 2);
        uint256 o = bound(oSeed, 1, y - 2);
        uint32 fee = uint32(bound(feeSeed, 0, 500_000_000));
        (MakerVenue.Status st, uint256 capMin, uint256 capIn, uint256 capOut) =
            MakerVenue.caps(x, y, fee, o, type(uint256).max, 0, true, 10_000);
        vm.assume(st == MakerVenue.Status.OK && capIn < MAX_AMOUNT);
        MakerVenue.Maker memory m = _maker(x, y, fee, capIn, capMin);
        (, uint256 outAt) = MakerVenue.quoteExactIn(m, capIn);
        (, uint256 outNext) = MakerVenue.quoteExactIn(m, capIn + 1);
        assertEq(outAt, capOut, "capOut is the output at capIn");
        assertLe(outAt, o, "the cap's output is within the output cap");
        assertGt(outNext, o, "one more input breaks the output cap");
    }

    // ---------------------------------------------------------------- band edge (named risk 2)

    /// @dev The oracle for the true (real-number) band edge in net input, written apart from the library: the net input
    ///      at which the curve's price reaches the band's edge. 0 when there is no edge (token0 in, band 100%).
    function _trueEdgeNet(uint256 x, uint256 y, int24 snap, bool zeroIn, uint16 bps) internal pure returns (uint256) {
        uint256 s = TickMath.getSqrtPriceAtTick(snap);
        uint256 ref = s * s;
        uint256 lim = FullMath.mulDiv(ref, bps, 10_000);
        uint256 w = zeroIn
            ? (ref - lim == 0 ? 0 : FullMath.mulDiv(y, 2 ** 192, ref - lim))
            : FullMath.mulDiv(y, ref + lim + 1, 2 ** 192);
        return w > x ? w - x : 0;
    }

    /// @dev Every fill in `[capMin, capIn]` the test can name must pass the real guard: the first and last integers, the
    ///      output levels just above `capMin` and the ~50 below `capIn` (each level's first and last input, where the
    ///      output's rounding is worst), and a spread between.
    function _density(MakerVenue.Maker memory m, int24 snap, bool zeroIn, uint16 bps) internal {
        uint256 lo = m.capMin;
        uint256 hi = m.capIn;
        assertGt(hi, 0, "cap is zero");
        assertLe(lo, hi, "capMin above cap");
        for (uint256 a = lo; a < lo + 150 && a <= hi; a++) {
            assertTrue(_fillPasses(m, snap, zeroIn, bps, a), "a just above capMin fails");
        }
        for (uint256 a = hi; a + 150 > hi && a >= lo; a--) {
            assertTrue(_fillPasses(m, snap, zeroIn, bps, a), "a just below the cap fails");
            if (a == 0) break;
        }
        // 50 output levels below the cap: the last input of each (worst rounding) and the first.
        (, uint256 b) = MakerVenue.quoteExactIn(m, hi);
        uint256 end = _maxGrossWithOut(m, b);
        for (uint256 k; k < 50 && b > 0; k++) {
            uint256 top = end > hi ? hi : end;
            if (top < lo) break;
            assertTrue(_fillPasses(m, snap, zeroIn, bps, top), "last input of a level below the cap fails");
            b -= 1;
            end = _maxGrossWithOut(m, b);
            uint256 first = end + 1;
            if (first >= lo && first <= hi) assertTrue(_fillPasses(m, snap, zeroIn, bps, first), "first input fails");
        }
        // 50 output levels above capMin.
        (, b) = MakerVenue.quoteExactIn(m, lo);
        end = _maxGrossWithOut(m, b);
        for (uint256 k; k < 50; k++) {
            uint256 top = end > hi ? hi : end;
            if (top >= lo) {
                assertTrue(_fillPasses(m, snap, zeroIn, bps, top), "last input of a level above capMin fails");
            }
            if (end >= hi) break;
            b += 1;
            end = _maxGrossWithOut(m, b);
        }
    }

    function _regime(string memory name, int24 snap, bool zeroIn, uint256 x, uint16 bps) internal {
        uint256 y = _reserves(snap, zeroIn, x);
        (MakerVenue.Status st, uint256 capMin, uint256 capIn,) =
            MakerVenue.caps(x, y, FEE, y, type(uint256).max, snap, zeroIn, bps);
        assertEq(uint8(st), uint8(MakerVenue.Status.OK), string.concat(name, ": status"));
        MakerVenue.Maker memory m = _maker(x, y, FEE, capIn, capMin);
        _density(m, snap, zeroIn, bps);
        // Worst-case gap between the cap and the true edge, in net input and relative (1e18 = 100%).
        (uint256 netCap,) = MakerVenue.quoteExactIn(m, capIn);
        uint256 edge = _trueEdgeNet(x, y, snap, zeroIn, bps);
        if (edge != 0 && edge < MAX_AMOUNT) {
            assertLe(netCap, edge, "cap past the true edge");
            emit log_named_uint(string.concat(name, ": bps ", vm.toString(bps), " gap (net wei)"), edge - netCap);
            emit log_named_uint(string.concat(name, ": gap relative 1e18"), (edge - netCap) * 1e18 / edge);
            emit log_named_uint(string.concat(name, ": capMin / cap relative 1e18"), capMin * 1e18 / capIn);
        }
    }

    function _regimeSet(string memory name, int24 snap, uint256 x0, uint256 x1) internal {
        uint16[3] memory bpsList = [uint16(1), 200, 10_000];
        for (uint256 i; i < 3; i++) {
            _regime(string.concat(name, " token0 in"), snap, true, x0, bpsList[i]);
            _regime(string.concat(name, " token1 in"), snap, false, x1, bpsList[i]);
        }
    }

    function test_V206_bandCapPassesRegime6to18() public {
        // 100,000 USDC (6 decimals) against 100,000 MUMB (18 decimals) at the fork pool's tick.
        _regimeSet("USDC<->MUMB", TICK_6_18, 100_000e6, 100_000e18);
    }

    function test_V206_bandCapPassesRegime18to6() public {
        // The same pair seen from the other side: a thin 18-decimal input against a 6-decimal output.
        _regimeSet("MUMB-heavy", TICK_6_18, 1_000e6, 1_000e18);
    }

    function test_V206_bandCapPassesRegime18x18AtTick0() public {
        _regimeSet("18/18 tick 0", 0, 100_000e18, 100_000e18);
    }

    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_V206_bandCapPasses(
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
        // The start price sits inside the band, up to half its width off the snapshot price, either side.
        uint256 d = bound(devSeed, 0, uint256(bps) / 2);
        uint256 factor = devSeed % 2 == 0 ? 10_000 + d : 10_000 - d;
        uint256 y = zeroIn
            ? FullMath.mulDiv(x, ref * factor, (2 ** 192) * 10_000)
            : FullMath.mulDiv(x, (2 ** 192) * 10_000, ref * factor);
        vm.assume(y >= 1e6 && y <= MAX_AMOUNT);
        (MakerVenue.Status st, uint256 capMin, uint256 capIn,) =
            MakerVenue.caps(x, y, fee, y, type(uint256).max, snap, zeroIn, bps);
        vm.assume(st == MakerVenue.Status.OK);
        assertGt(capIn, 0, "cap is zero");
        MakerVenue.Maker memory m = _maker(x, y, fee, capIn, capMin);
        uint256 span = capIn - capMin + 1;
        uint256[8] memory picks = [
            capMin,
            capIn,
            capMin + 1 > capIn ? capIn : capMin + 1,
            capIn - 1 < capMin ? capMin : capIn - 1,
            capMin + uint256(keccak256(abi.encode(pick, 0))) % span,
            capMin + uint256(keccak256(abi.encode(pick, 1))) % span,
            capMin + uint256(keccak256(abi.encode(pick, 2))) % span,
            capMin + uint256(keccak256(abi.encode(pick, 3))) % span
        ];
        for (uint256 i; i < 8; i++) {
            assertTrue(_fillPasses(m, snap, zeroIn, bps, picks[i]), "a fill inside [capMin, cap] is refused");
        }
    }

    // ---------------------------------------------------------------- the mirrors equal the guard (drift and band)

    function _checkMirror(int24 snap, int56 emaX, bool zeroIn, uint16 bps, uint16 drift, uint256 net, uint256 out)
        internal
    {
        (bool ok, bytes4 sel) = _guard(snap, emaX, zeroIn, bps, drift, net, out);
        bool driftOk = MakerVenue.driftPasses(snap, emaX, drift);
        bool bandOk = MakerVenue.bandPasses(snap, zeroIn, bps, net, out);
        if (!driftOk) {
            assertFalse(ok, "guard passed past the drift limit");
            assertEq(sel, AnchorDrift.selector, "wrong refusal for drift");
        } else {
            assertEq(ok, bandOk, "band mirror differs from the guard");
            if (!ok) assertTrue(sel == BandExceeded.selector || sel == BandNotComputed.selector, "wrong refusal");
        }
    }

    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_V206_mirrorEqualsGuardNearEdges(
        int24 tickSeed,
        uint16 bpsSeed,
        uint16 driftSeed,
        uint256 nSeed,
        uint256 edgeSeed,
        uint256 emaSeed,
        bool zeroIn
    ) public {
        int24 snap = int24(bound(int256(tickSeed), -250_000, 250_000));
        uint16 bps = uint16(bound(bpsSeed, 1, 10_000));
        uint16 drift = uint16(bound(driftSeed, 0, 10_000));
        // The EMA sits at the drift limit, one unit inside, one unit outside, or anywhere.
        int256 off;
        uint256 c = emaSeed % 4;
        if (c == 0) off = int256(uint256(drift)) * UNIT - 1;
        else if (c == 1) off = int256(uint256(drift)) * UNIT;
        else if (c == 2) off = int256(uint256(drift)) * UNIT + 1;
        else off = int256(bound(emaSeed >> 8, 0, 20_000 * uint256(UNIT)));
        int56 emaX = int56(int256(snap) * UNIT + ((emaSeed >> 4) % 2 == 0 ? off : -off));
        // The fill sits at the band's edge, one wei of price inside or outside, or a little further out.
        uint256 s = TickMath.getSqrtPriceAtTick(snap);
        uint256 ref = s * s;
        uint256 lim = FullMath.mulDiv(ref, bps, 10_000);
        uint256 execT = edgeSeed % 2 == 0 ? ref + lim : ref - lim;
        uint256 e = (edgeSeed >> 1) % 5;
        if (e == 0) execT -= 1;
        else if (e == 2) execT += 1;
        else if (e == 3) execT += ref / 1e9;
        else if (e == 4) execT -= ref / 1e9 < execT ? ref / 1e9 : 0;
        uint256 net = bound(nSeed, 1e3, 1e27);
        uint256 out = zeroIn ? FullMath.mulDiv(net, execT, 2 ** 192) : FullMath.mulDiv(net, 2 ** 192, execT);
        _checkMirror(snap, emaX, zeroIn, bps, drift, net, out);
    }

    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_V206_mirrorEqualsGuardWideRange(
        int24 tickSeed,
        uint16 bpsSeed,
        uint16 driftSeed,
        uint256 netSeed,
        uint256 outSeed,
        int56 emaSeed,
        bool zeroIn
    ) public {
        int24 snap = int24(bound(int256(tickSeed), TickMath.MIN_TICK + 1, TickMath.MAX_TICK - 1));
        uint16 bps = uint16(bound(bpsSeed, 1, 10_000));
        uint16 drift = uint16(bound(driftSeed, 0, 10_000));
        int56 emaX =
            int56(bound(int256(emaSeed), int256(snap) * UNIT - 12_000 * UNIT, int256(snap) * UNIT + 12_000 * UNIT));
        // Sizes over the full word: small, huge, and saturating.
        uint256 net = netSeed % 3 == 0
            ? bound(netSeed >> 8, 1, 1e6)
            : (netSeed % 3 == 1 ? bound(netSeed >> 8, 1, 2 ** 128) : netSeed >> 8);
        uint256 out = outSeed % 3 == 0
            ? bound(outSeed >> 8, 0, 1e6)
            : (outSeed % 3 == 1 ? bound(outSeed >> 8, 1, 2 ** 128) : outSeed >> 8);
        _checkMirror(snap, emaX, zeroIn, bps, drift, net, out);
    }
}

/// @notice V2-06 on the mainnet fork: real strategies in real Aqua, filled through the canonical router.
/// @dev Strategies are open (`exclusive: false`) so `TakerHelper` can fill and `router.quote` is allowed; the exclusive
///      taker rule is V2-04's and V2-05's. USDC is currency0 (checked by `RegistryBase.setUp`), so `zeroForOne` means
///      USDC in and MUMB out.
contract V206MakerVenueForkTest is RegistryBase {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant M = 100_000e18;
    uint256 internal constant U = 100_000e6;

    MakerVenueHarness internal harness;
    TakerHelper internal helper;

    function setUp() public override {
        super.setUp();
        harness = new MakerVenueHarness();
        helper = new TakerHelper(ISwapVM(ROUTER));
        // `register` needs the pool's anchor (a swap has happened); every later read is in this same block, so the
        // venue and the guard see one anchor.
        _initAnchor();
    }

    // ---------------------------------------------------------------- helpers

    function _open() internal pure returns (StrategyTemplate.Params memory) {
        return StrategyTemplate.Params({feeE9: FEE_0_30_PCT, bandBps: 200, driftTicks: 300, exclusive: false, salt: 0});
    }

    function _entries() internal view returns (MakerVenue.Entry[] memory e) {
        ConfluenceHook.Slot[] memory s = hookV2.strategiesOf(idV2);
        e = new MakerVenue.Entry[](s.length);
        for (uint256 i; i < s.length; i++) {
            e[i] = MakerVenue.Entry({maker: s[i].maker, params: s[i].params, strategyHash: s[i].strategyHash});
        }
    }

    function _readEntries(MakerVenue.Entry[] memory e, bool zfo) internal view returns (MakerVenue.Maker[] memory) {
        (int24 snap, int56 emaX,) = hookV2.anchorOfX(idV2);
        return harness.read(manager, keyV2, _guard(), e, zfo, snap, emaX);
    }

    function _read(bool zfo) internal view returns (MakerVenue.Maker[] memory) {
        return _readEntries(_entries(), zfo);
    }

    function _one(address maker, bool zfo) internal view returns (MakerVenue.Maker memory) {
        MakerVenue.Maker[] memory ms = _read(zfo);
        for (uint256 i; i < ms.length; i++) {
            if (ms[i].maker == maker) return ms[i];
        }
        revert("maker not read");
    }

    function _tokenIn(bool zfo) internal view returns (address) {
        return zfo ? USDC : address(mumb);
    }

    function _tokenOut(bool zfo) internal view returns (address) {
        return zfo ? address(mumb) : USDC;
    }

    function _virtual(address maker, bytes32 h, address token) internal view returns (uint256 v) {
        (v,) = IAqua(AQUA).rawBalances(maker, ROUTER, h, token);
    }

    function _giveHelper(address token, uint256 amount) internal {
        if (token == USDC) {
            deal(USDC, address(helper), amount);
        } else {
            vm.prank(deployer);
            mumb.mint(address(helper), amount);
        }
    }

    function _order(address maker, StrategyTemplate.Params memory p) internal view returns (ISwapVM.Order memory) {
        return StrategyTemplate.order(maker, _program(p));
    }

    /// @dev A real router fill by `helper`; returns the output.
    function _fill(address maker, StrategyTemplate.Params memory p, bool zfo, uint256 a)
        internal
        returns (uint256 out)
    {
        _giveHelper(_tokenIn(zfo), a);
        (, out,) = helper.swapExactIn(_order(maker, p), _tokenIn(zfo), _tokenOut(zfo), a, 0, trader);
    }

    /// @dev The router's own quote (allowed: the strategy is open).
    function _routerQuote(address maker, StrategyTemplate.Params memory p, bool zfo, uint256 a)
        internal
        view
        returns (uint256 in_, uint256 out)
    {
        (in_, out,) = helper.quoteExactIn(_order(maker, p), _tokenIn(zfo), _tokenOut(zfo), a, 0);
    }

    function _quote(MakerVenue.Maker memory m, uint256 a) internal view returns (uint256 out) {
        (, out) = harness.quoteExactIn(m, a);
    }

    /// @dev A fill at `a` on a copy of the state: exact balances of maker, Aqua, trader, helper and hook. Returns out.
    function _fillExact(address maker, StrategyTemplate.Params memory p, bool zfo, uint256 a, uint256 expectOut)
        internal
        returns (uint256 out)
    {
        bytes32 h = _hash(maker, p);
        address tin = _tokenIn(zfo);
        address tout = _tokenOut(zfo);
        uint256 wIn = IERC20(tin).balanceOf(maker);
        uint256 wOut = IERC20(tout).balanceOf(maker);
        uint256 vIn = _virtual(maker, h, tin);
        uint256 vOut = _virtual(maker, h, tout);
        uint256 tOut = IERC20(tout).balanceOf(trader);
        out = _fill(maker, p, zfo, a);
        assertEq(out, expectOut, "fill output differs from the venue's prediction");
        assertEq(IERC20(tin).balanceOf(maker), wIn + a, "maker wallet, input side");
        assertEq(IERC20(tout).balanceOf(maker), wOut - out, "maker wallet, output side");
        assertEq(_virtual(maker, h, tin), vIn + a, "Aqua virtual, input side (gross)");
        assertEq(_virtual(maker, h, tout), vOut - out, "Aqua virtual, output side");
        assertEq(IERC20(tout).balanceOf(trader) - tOut, out, "trader received");
        assertEq(IERC20(tin).balanceOf(address(helper)), 0, "helper keeps input");
        assertEq(IERC20(tout).balanceOf(address(helper)), 0, "helper keeps output");
        assertEq(IERC20(USDC).balanceOf(address(hookV2)), 0, "hook holds USDC");
        assertEq(mumb.balanceOf(address(hookV2)), 0, "hook holds MUMB");
    }

    /// @dev The cap is tight against a binding limit `lim` on the output: out(cap) <= lim < out(cap + 1), by the router's
    ///      own quote, and a real fill at the cap succeeds with the predicted output.
    function _assertTightAt(address maker, StrategyTemplate.Params memory p, bool zfo, uint256 lim)
        internal
        returns (MakerVenue.Maker memory m)
    {
        m = _one(maker, zfo);
        assertEq(uint8(m.status), uint8(MakerVenue.Status.OK), "status");
        assertGt(m.capIn, 0, "cap is zero");
        (uint256 inAt, uint256 outAt) = _routerQuote(maker, p, zfo, m.capIn);
        assertEq(inAt, m.capIn);
        assertLe(outAt, lim, "output at the cap passes the limit");
        assertEq(outAt, m.capOut, "capOut is the output at the cap");
        (, uint256 outNext) = _routerQuote(maker, p, zfo, m.capIn + 1);
        assertGt(outNext, lim, "one more input would pass the limit: the cap is not tight");
        uint256 snap = vm.snapshotState();
        _fillExact(maker, p, zfo, m.capIn, m.capOut);
        vm.revertToState(snap);
    }

    function _joinOpen(address m, uint256 mumbAmt, uint256 usdcAmt) internal {
        _join(m, mumbAmt, usdcAmt, _open());
    }

    function _eq(MakerVenue.Maker memory a, MakerVenue.Maker memory b) internal pure returns (bool) {
        return a.maker == b.maker && a.strategyHash == b.strategyHash && a.status == b.status && a.x == b.x
            && a.y == b.y && a.feeE9 == b.feeE9 && a.capMin == b.capMin && a.capIn == b.capIn && a.capOut == b.capOut;
    }

    // ---------------------------------------------------------------- spec acceptance

    function test_V206_capFromWallet() public {
        address m0 = makers[0];
        _joinOpen(m0, M, U);
        MakerVenue.Maker memory before_ = _one(m0, true);
        assertEq(uint8(before_.status), uint8(MakerVenue.Status.OK));
        assertEq(before_.x, U, "x is the virtual USDC");
        assertEq(before_.y, M, "y is the virtual MUMB");
        // The maker spends MUMB elsewhere and keeps 700.
        vm.prank(m0);
        mumb.transfer(makers[5], M - 700e18);
        MakerVenue.Maker memory m = _assertTightAt(m0, _open(), true, 700e18);
        assertLe(m.capOut, 700e18, "output past the wallet");
        assertLt(m.capIn, before_.capIn, "the cap did not shrink");
    }

    function test_V206_sharedWallet() public {
        address m0 = makers[0];
        _joinOpen(m0, M, U);
        // A second Aqua strategy of the same maker, not registered: it backs the same 100,000 MUMB and has a wide band.
        StrategyTemplate.Params memory p2 = StrategyTemplate.Params({
            feeE9: FEE_0_30_PCT, bandBps: 10_000, driftTicks: 10_000, exclusive: false, salt: 1
        });
        _ship(m0, p2, M, U);
        // 20,000,000 USDC into it takes about 99,500 MUMB out of the shared wallet.
        _fill(m0, p2, true, 20_000_000e6);
        uint256 wallet = mumb.balanceOf(m0);
        assertLt(wallet, 600e18, "the second strategy did not drain the wallet");
        assertGt(wallet, 0);
        MakerVenue.Maker memory m = _assertTightAt(m0, _open(), true, wallet);
        assertEq(m.y, M, "the registered strategy's virtual MUMB is untouched");
        assertLe(m.capOut, wallet);
        // The registry's depth takes the same per-token minimum: one shared function (carry-over 1).
        (int24 snap,,) = hookV2.anchorOfX(idV2);
        uint256 realMumb = harness.real(address(mumb), m0, M);
        uint256 realUsdc = harness.real(USDC, m0, U);
        assertEq(realMumb, wallet);
        assertEq(hookV2.depthOf(keyV2, m0), StrategyTemplate.depthValue(realUsdc, realMumb, snap), "depth != cap's min");
    }

    function test_V206_offMarketDropped() public {
        _joinOpen(makers[0], 105_000e18, U); // price 5% above the market
        _joinOpen(makers[1], 95_000e18, U); // 5% below
        _joinOpen(makers[2], 101_000e18, U); // 1% above: inside the 2% band
        bool[2] memory dirs = [true, false];
        for (uint256 d; d < 2; d++) {
            MakerVenue.Maker[] memory ms = _read(dirs[d]);
            assertEq(uint8(ms[0].status), uint8(MakerVenue.Status.SKIP_BAND), "5% above is dropped");
            assertEq(uint8(ms[1].status), uint8(MakerVenue.Status.SKIP_BAND), "5% below is dropped");
            assertEq(uint8(ms[2].status), uint8(MakerVenue.Status.OK), "1% off stays");
            assertEq(ms[0].capIn, 0);
            assertEq(ms[1].capIn, 0);
            (SplitMath.Venue[] memory v, uint256[] memory idx) = harness.toVenues(ms);
            assertEq(v.length, 1, "only the in-band maker is a venue");
            assertEq(idx[0], 2);
            assertEq(v[0].cap, ms[2].capIn);
        }
    }

    function test_V206_driftDropped() public {
        _joinOpen(makers[0], M, U);
        (int24 snap, int56 emaX,) = hookV2.anchorOfX(idV2);
        int56 limit = int56(300 * 65_536);
        int56 flat = int56(int256(snap) * 65_536);
        MakerVenue.Entry[] memory e = _entries();
        bool[2] memory dirs = [true, false];
        for (uint256 d; d < 2; d++) {
            // The recorded EMA is the snapshot's (first touch): zero drift.
            assertEq(emaX, flat);
            int56[4] memory emas = [flat + limit, flat - limit, flat + limit + 1, flat - limit - 1];
            for (uint256 i; i < 4; i++) {
                MakerVenue.Maker[] memory ms = harness.read(manager, keyV2, _guard(), e, dirs[d], snap, emas[i]);
                MakerVenue.Status want = i < 2 ? MakerVenue.Status.OK : MakerVenue.Status.SKIP_DRIFT;
                assertEq(uint8(ms[0].status), uint8(want), "drift edge");
                if (want == MakerVenue.Status.SKIP_DRIFT) assertEq(ms[0].capIn, 0);
            }
        }
    }

    function test_V206_bandCapMatchesGuard() public {
        address m0 = makers[0];
        StrategyTemplate.Params memory p = _open();
        _joinOpen(m0, M, U);
        bool[2] memory dirs = [true, false];
        for (uint256 d; d < 2; d++) {
            bool zfo = dirs[d];
            MakerVenue.Maker memory m = _one(m0, zfo);
            assertEq(uint8(m.status), uint8(MakerVenue.Status.OK));
            assertGt(m.capIn, m.capMin, "no band between capMin and the cap");
            uint256[4] memory fills = [m.capMin, m.capMin + 1, m.capIn - 1, m.capIn];
            for (uint256 i; i < 4; i++) {
                uint256 snap = vm.snapshotState();
                uint256 out = _fill(m0, p, zfo, fills[i]);
                assertEq(out, _quote(m, fills[i]), "fill != prediction");
                vm.revertToState(snap);
            }
            // Past the cap the guard refuses within a small slack: find the first power of two that fails, then
            // refuse it on the real router.
            uint256 slack = 1;
            while (slack < 2 ** 70) {
                (bool ok, bytes memory ret) = address(helper)
                    .staticcall(
                        abi.encodeCall(
                            TakerHelper.quoteExactIn, (_order(m0, p), _tokenIn(zfo), _tokenOut(zfo), m.capIn + slack, 0)
                        )
                    );
                if (!ok) {
                    assertEq(bytes4(ret), BandExceeded.selector, "refused for another reason");
                    break;
                }
                slack *= 2;
            }
            assertLt(slack, 2 ** 70, "the guard never refused above the cap");
            emit log_named_uint(zfo ? "token0 in: smallest power-of-two slack past the cap" : "token1 in: slack", slack);
            _giveHelper(_tokenIn(zfo), m.capIn + slack);
            vm.expectPartialRevert(BandExceeded.selector);
            helper.swapExactIn(_order(m0, p), _tokenIn(zfo), _tokenOut(zfo), m.capIn + slack, 0, trader);
        }
    }

    function test_V206_predictionEqualsRouterQuote() public {
        address m0 = makers[0];
        StrategyTemplate.Params memory p = _open();
        _joinOpen(m0, M, U);
        bool[2] memory dirs = [true, false];
        uint256[5] memory num = [uint256(0), 1, 3, 4, 5];
        for (uint256 d; d < 2; d++) {
            MakerVenue.Maker memory m = _one(m0, dirs[d]);
            for (uint256 k; k < 5; k++) {
                uint256 a = m.capMin + (m.capIn - m.capMin) * num[k] / 5;
                (uint256 rIn, uint256 rOut) = _routerQuote(m0, p, dirs[d], a);
                assertEq(rIn, a);
                assertEq(_quote(m, a), rOut, "prediction != router quote");
            }
        }
    }

    // ---------------------------------------------------------------- named risks

    function test_V206_fillAtCapEqualsPrediction() public {
        address m0 = makers[0];
        StrategyTemplate.Params memory p = _open();
        _joinOpen(m0, M, U);
        bool[2] memory dirs = [true, false];
        for (uint256 d; d < 2; d++) {
            MakerVenue.Maker memory m = _one(m0, dirs[d]);
            uint256 snap = vm.snapshotState();
            _fillExact(m0, p, dirs[d], m.capIn, _quote(m, m.capIn));
            vm.revertToState(snap);
            snap = vm.snapshotState();
            _fillExact(m0, p, dirs[d], m.capMin, _quote(m, m.capMin));
            vm.revertToState(snap);
        }
    }

    function test_V206_capFollowsWalletAllowanceAndVirtual() public {
        StrategyTemplate.Params memory p = _open();
        // m0: wallet cut. m1: allowance cut. m2: a virtual balance lower than the wallet, then a fill by someone else.
        _joinOpen(makers[0], M, U);
        _joinOpen(makers[1], M, U);
        _fund(makers[2], M, U);
        _ship(makers[2], p, 380e18, U);
        _register(makers[2], p);

        vm.prank(makers[0]);
        mumb.transfer(makers[5], M - 600e18);
        _assertTightAt(makers[0], p, true, 600e18);

        vm.prank(makers[1]);
        mumb.approve(AQUA, 450e18);
        _assertTightAt(makers[1], p, true, 450e18);

        MakerVenue.Maker memory before_ = _assertTightAt(makers[2], p, true, 380e18);
        _fill(makers[2], p, true, 100e6); // someone else uses 100 USDC of it
        uint256 left = _virtual(makers[2], _hash(makers[2], p), address(mumb));
        assertLt(left, 380e18);
        MakerVenue.Maker memory after_ = _assertTightAt(makers[2], p, true, left);
        assertLt(after_.capIn, before_.capIn, "the cap did not follow the virtual balance");

        // Cutting the other direction's token moves the other direction's cap, not this one.
        vm.prank(makers[0]);
        IERC20(USDC).approve(AQUA, 0);
        MakerVenue.Maker memory oneIn = _one(makers[0], false);
        assertEq(uint8(oneIn.status), uint8(MakerVenue.Status.SKIP_UNDERFUNDED), "no USDC allowance: no USDC output");
        assertEq(oneIn.capIn, 0);
        assertEq(_one(makers[0], true).capIn, _assertTightAt(makers[0], p, true, 600e18).capIn);
    }

    function test_V206_brokenMakerSkipped() public {
        StrategyTemplate.Params memory p = _open();
        _joinOpen(makers[0], M, U); // healthy
        _joinOpen(makers[1], 90_000e18, 90_000e6); // healthy
        _joinOpen(makers[2], M, U); // to be docked
        _joinOpen(makers[3], M, U); // to be drained
        _joinOpen(makers[4], M, U); // allowance to be revoked
        _fund(makers[5], M, 0); // zero USDC reserve: depth comes from the MUMB side only
        _ship(makers[5], p, M, 0);
        _register(makers[5], p);

        bytes32 dockedHash = _hash(makers[2], p); // computed first: `prank` applies to the next call only
        vm.prank(makers[2]);
        IAqua(AQUA).dock(ROUTER, dockedHash, _tokens());
        vm.startPrank(makers[3]);
        mumb.transfer(makers[6], mumb.balanceOf(makers[3]));
        IERC20(USDC).transfer(makers[6], IERC20(USDC).balanceOf(makers[3]));
        vm.stopPrank();
        vm.startPrank(makers[4]);
        mumb.approve(AQUA, 0);
        IERC20(USDC).approve(AQUA, 0);
        vm.stopPrank();

        MakerVenue.Entry[] memory all = _entries();
        MakerVenue.Entry[] memory healthy = new MakerVenue.Entry[](2);
        healthy[0] = all[0];
        healthy[1] = all[1];
        bool[2] memory dirs = [true, false];
        for (uint256 d; d < 2; d++) {
            MakerVenue.Maker[] memory ms = _readEntries(all, dirs[d]); // must not revert
            MakerVenue.Maker[] memory alone = _readEntries(healthy, dirs[d]);
            assertEq(ms.length, 6);
            for (uint256 i; i < 2; i++) {
                assertEq(uint8(ms[i].status), uint8(MakerVenue.Status.OK), "healthy maker dropped");
                assertGt(ms[i].capIn, 0);
                assertTrue(_eq(ms[i], alone[i]), "a broken maker changed a healthy maker's venue");
            }
            for (uint256 i = 2; i < 6; i++) {
                assertEq(uint8(ms[i].status), uint8(MakerVenue.Status.SKIP_UNDERFUNDED), "broken maker kept");
                assertEq(ms[i].capIn, 0);
                assertEq(ms[i].capOut, 0);
            }
            (SplitMath.Venue[] memory v, uint256[] memory idx) = harness.toVenues(ms);
            assertEq(v.length, 2);
            assertEq(idx[0], 0);
            assertEq(idx[1], 1);
            for (uint256 i; i < 2; i++) {
                assertEq(v[i].x, ms[i].x);
                assertEq(v[i].y, ms[i].y);
                assertEq(v[i].feeE9, ms[i].feeE9);
                assertEq(v[i].cap, ms[i].capIn);
            }
        }
        // A tampered entry (parameters that were never shipped) is skipped, not trusted for pricing.
        MakerVenue.Entry[] memory tampered = new MakerVenue.Entry[](1);
        tampered[0] = all[0];
        tampered[0].params.bandBps = 201;
        assertEq(uint8(_readEntries(tampered, true)[0].status), uint8(MakerVenue.Status.SKIP_UNDERFUNDED));
        tampered[0] = all[0];
        tampered[0].strategyHash = bytes32(uint256(1)); // stored hash that is not the rebuilt one
        assertEq(uint8(_readEntries(tampered, true)[0].status), uint8(MakerVenue.Status.SKIP_UNDERFUNDED));
    }

    function test_V206_bothDirectionsAgree() public {
        address m0 = makers[0];
        StrategyTemplate.Params memory p = _open();
        // Asymmetric on purpose: virtual 101,000 MUMB / 100,000 USDC (price 1.01), wallets 700 MUMB / 900 USDC.
        _fund(m0, 700e18, 900e6);
        _ship(m0, p, 101_000e18, 100_000e6);
        _register(m0, p);

        MakerVenue.Maker memory z = _assertTightAt(m0, p, true, 700e18); // USDC in, MUMB out
        assertEq(z.x, 100_000e6, "token0 in: x is USDC");
        assertEq(z.y, 101_000e18, "token0 in: y is MUMB");
        MakerVenue.Maker memory o = _assertTightAt(m0, p, false, 900e6); // MUMB in, USDC out
        assertEq(o.x, 101_000e18, "token1 in: x is MUMB");
        assertEq(o.y, 100_000e6, "token1 in: y is USDC");
        assertEq(z.feeE9, o.feeE9);
        assertLe(z.capOut, 700e18);
        assertLe(o.capOut, 900e6);
    }

    function test_V206_sixMakersBounded() public {
        for (uint256 i; i < 6; i++) {
            _join(makers[i], (i + 1) * 20_000e18, (i + 1) * 20_000e6, _open());
        }
        assertEq(hookV2.strategiesOf(idV2).length, 6);
        // Padded to 8 entries, only MAX_STRATEGIES are read: 2 Aqua reads per maker, nothing more.
        MakerVenue.Entry[] memory six = _entries();
        MakerVenue.Entry[] memory eight = new MakerVenue.Entry[](8);
        for (uint256 i; i < 8; i++) {
            eight[i] = six[i % 6];
        }
        vm.expectCall(AQUA, abi.encodeWithSelector(IAqua.rawBalances.selector), 12);
        vm.expectCall(address(mumb), abi.encodeWithSelector(IERC20.allowance.selector), 6);
        vm.expectCall(USDC, abi.encodeWithSelector(IERC20.allowance.selector), 0);
        MakerVenue.Maker[] memory ms = _readEntries(eight, true);
        assertEq(ms.length, 6);

        // Gas (logged, not asserted; V2-11 budgets): cold-ish, as the first read in a swap would be.
        uint256[3] memory counts = [uint256(1), 3, 6];
        for (uint256 c; c < 3; c++) {
            MakerVenue.Entry[] memory e = new MakerVenue.Entry[](counts[c]);
            for (uint256 i; i < counts[c]; i++) {
                e[i] = six[i];
            }
            vm.cool(AQUA);
            vm.cool(USDC);
            vm.cool(address(mumb));
            vm.cool(POOL_MANAGER);
            uint256 g0 = gasleft();
            _readEntries(e, true);
            emit log_named_uint(
                string.concat("gas, read of ", vm.toString(counts[c]), " maker(s), cold"), g0 - gasleft()
            );
        }
    }

    function test_V206_constantsAndSharedMin() public view {
        assertEq(harness.maxMakers(), hookV2.MAX_STRATEGIES(), "MAX_MAKERS");
        assertEq(harness.aqua(), hookV2.AQUA());
        assertEq(harness.router(), hookV2.ROUTER());
    }
}
