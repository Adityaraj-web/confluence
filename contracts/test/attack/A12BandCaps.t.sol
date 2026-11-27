// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, stdError} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";

import {BandGuardV2} from "../../src/BandGuardV2.sol";
import {MakerVenue} from "../../src/libraries/MakerVenue.sol";
import {MockAnchorHook} from "../unit/V204BandGuard.t.sol";

/// @notice V2-10 (carry-over from V2-06 and V2-08): the exact-input and exact-output band caps against the REAL
///         `BandGuardV2`, over the WIDE domain the earlier fuzzers never reached, with no RPC.
/// @dev V206's and V208's generators stay inside |tick| <= 300,000 with makers of 1e9 to 1e30 (X192 scale only). This
///      file's generator is new and scoped to this file: it stratifies the snapshot tick over four ranges (today's,
///      300,000 to 429,800, 429,800 up to the top tick including its last few ticks, and the negative far side), builds
///      the pair from the LARGER side so both reserves land in range, and adds 1 to 3 wei makers (where the reserves
///      are tiny against a huge price). `test_V210_coverage` loops fixed seeds and asserts every stratum, mode and
///      direction produced real caps, so a green fuzz run is not vacuous.
contract A12BandCapsTest is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant PM = address(0x9999);
    address internal constant TOKEN0 = address(0x1000);
    address internal constant TOKEN1 = address(0x2000);
    uint24 internal constant LP_FEE = 500;
    int24 internal constant SPACING = 10;
    int256 internal constant UNIT = 2 ** 16;
    uint256 internal constant MAX_AMOUNT = type(uint128).max;
    int24 internal constant TOP = 887_270;

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

    // ---------------------------------------------------------------- the real guard

    function _pack(uint16 bandBps) internal view returns (bytes memory) {
        return abi.encodePacked(PM, TOKEN0, TOKEN1, LP_FEE, SPACING, address(mock), bandBps, uint16(300), uint8(0));
    }

    function _guard(int24 snap, bool zeroIn, bool isExactIn, uint16 bandBps, uint256 net, uint256 out)
        internal
        returns (bool ok)
    {
        mock.set(id, snap, int56(int256(snap) * UNIT));
        SwapQuery memory q = SwapQuery(
            bytes32(uint256(1)),
            address(1),
            address(0xBEEF),
            zeroIn ? TOKEN0 : TOKEN1,
            zeroIn ? TOKEN1 : TOKEN0,
            isExactIn
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

    // ---------------------------------------------------------------- the generator

    /// @dev Snapshot tick of stratum `st` (0 to 3): 0 today's domain; 1 either sign 300,000 to 429,800 (X192 scale, never
    ///      reached before); 2 positive 429,800 up to the top tick, half of it in the last 70 ticks; 3 negative far side.
    function _tick(uint256 st, uint256 seed) internal pure returns (int24) {
        if (st == 0) return int24(int256(seed % 600_001) - 300_000);
        if (st == 1) {
            int256 m = int256(300_000 + seed % 129_801);
            return int24((seed >> 64) % 2 == 0 ? m : -m);
        }
        if (st == 2) {
            if ((seed >> 64) % 2 == 0) return int24(int256(429_800 + seed % uint256(int256(TOP) - 429_800 + 1)));
            return int24(int256(TOP) - int256(seed % 71));
        }
        return int24(-int256(300_000 + seed % uint256(int256(TOP) - 300_000 + 1)));
    }

    /// @notice A maker priced at the snapshot (up to half the band off it) with both reserves in `[1, 2^128)`, built
    ///         from the larger side. Reverts are caught by the caller (`ok` false).
    function pair(int24 snap, bool zeroIn, uint256 bigSeed, uint16 bps, uint256 devSeed, bool tiny)
        external
        pure
        returns (bool ok, uint256 x, uint256 y)
    {
        (uint256 ref, uint256 shift) = _scale(snap);
        if (tiny) {
            x = 1 + bigSeed % 3;
            y = zeroIn ? FullMath.mulDiv(x, ref, 2 ** shift) : FullMath.mulDiv(x, 2 ** shift, ref);
        } else {
            // log-uniform larger side: a random width of 1 to 128 bits
            uint256 bits = 1 + (bigSeed >> 200) % 128;
            uint256 big = (bigSeed % (2 ** bits)) | (2 ** (bits - 1));
            bool yLarger = zeroIn ? snap >= 0 : snap <= 0;
            if (yLarger) {
                y = big;
                x = zeroIn ? FullMath.mulDiv(y, 2 ** shift, ref) : FullMath.mulDiv(y, ref, 2 ** shift);
            } else {
                x = big;
                y = zeroIn ? FullMath.mulDiv(x, ref, 2 ** shift) : FullMath.mulDiv(x, 2 ** shift, ref);
            }
        }
        if (x == 0 || y == 0 || x > MAX_AMOUNT || y > MAX_AMOUNT) return (false, 0, 0);
        uint256 d = devSeed % (uint256(bps) / 2 + 1);
        uint256 factor = (devSeed >> 32) % 2 == 0 ? 10_000 + d : 10_000 - d;
        y = (y * factor) / 10_000;
        ok = y >= 1 && y <= MAX_AMOUNT;
    }

    struct Case {
        int24 snap;
        bool zeroIn;
        uint16 bps;
        uint32 fee;
        uint256 x;
        uint256 y;
        bool ok;
    }

    function _case(
        uint256 st,
        uint256 tickSeed,
        bool zeroIn,
        uint256 bigSeed,
        uint16 bpsSeed,
        uint256 devSeed,
        uint32 feeSeed
    ) internal view returns (Case memory c) {
        c.snap = _tick(st, tickSeed);
        c.zeroIn = zeroIn;
        c.bps = uint16(bound(bpsSeed, 1, 10_000));
        c.fee = uint32(bound(feeSeed, 0, 500_000_000));
        bool tiny = bigSeed % 5 == 0;
        try this.pair(c.snap, zeroIn, bigSeed, c.bps, devSeed, tiny) returns (bool ok, uint256 x, uint256 y) {
            (c.ok, c.x, c.y) = (ok, x, y);
        } catch {}
    }

    // ---------------------------------------------------------------- the checks

    /// @dev Exact input: the fills named below, all inside `[capMin, capIn]`, pass the real guard. Returns whether the
    ///      case produced a cap (false: the maker's own start price was outside its band, or the maths refused).
    function _checkIn(Case memory c, uint256 pick) internal returns (bool) {
        if (!c.ok) return false;
        (MakerVenue.Status st, uint256 capMin, uint256 capIn,) =
            MakerVenue.caps(c.x, c.y, c.fee, c.y, type(uint256).max, c.snap, c.zeroIn, c.bps);
        if (st != MakerVenue.Status.OK) return false;
        assertGt(capIn, 0, "cap is zero");
        MakerVenue.Maker memory m;
        (m.x, m.y, m.feeE9) = (c.x, c.y, c.fee);
        uint256 span = capIn - capMin + 1;
        uint256[6] memory picks = [
            capMin,
            capIn,
            capMin + 1 > capIn ? capIn : capMin + 1,
            capIn - 1 < capMin ? capMin : capIn - 1,
            capMin + uint256(keccak256(abi.encode(pick, 0))) % span,
            capMin + uint256(keccak256(abi.encode(pick, 1))) % span
        ];
        for (uint256 i; i < 6; i++) {
            (uint256 net, uint256 out) = MakerVenue.quoteExactIn(m, picks[i]);
            assertTrue(
                _guard(c.snap, c.zeroIn, true, c.bps, net, out), "an exact-in fill inside [capMin, cap] is refused"
            );
        }
        return true;
    }

    /// @dev Exact output: the same over `[bMin, bMax]`.
    function _checkOut(Case memory c, uint256 pick) internal returns (bool) {
        if (!c.ok) return false;
        (MakerVenue.Status st, uint256 bMin, uint256 bMax,) =
            MakerVenue.capsOut(c.x, c.y, c.fee, c.y, type(uint256).max, c.snap, c.zeroIn, c.bps);
        if (st != MakerVenue.Status.OK) return false;
        assertGt(bMax, 0, "cap is zero");
        assertLe(bMin, bMax, "bMin above bMax");
        MakerVenue.Maker memory m;
        (m.x, m.y, m.feeE9) = (c.x, c.y, c.fee);
        uint256 span = bMax - bMin + 1;
        uint256[6] memory picks = [
            bMin,
            bMax,
            bMin + 1 > bMax ? bMax : bMin + 1,
            bMax - 1 < bMin ? bMin : bMax - 1,
            bMin + uint256(keccak256(abi.encode(pick, 0))) % span,
            bMin + uint256(keccak256(abi.encode(pick, 1))) % span
        ];
        for (uint256 i; i < 6; i++) {
            (uint256 net,) = MakerVenue.quoteExactOut(m, picks[i]);
            assertTrue(
                _guard(c.snap, c.zeroIn, false, c.bps, net, picks[i]),
                "an exact-out fill inside [bMin, bMax] is refused"
            );
        }
        return true;
    }

    // ---------------------------------------------------------------- fuzz (50,000 runs, no RPC)

    /// forge-config: default.fuzz.runs = 50000
    function testFuzz_V210_bandCapInWideDomain(
        uint256 stSeed,
        uint256 tickSeed,
        bool zeroIn,
        uint256 bigSeed,
        uint16 bpsSeed,
        uint256 devSeed,
        uint32 feeSeed,
        uint256 pick
    ) public {
        Case memory c = _case(stSeed % 4, tickSeed, zeroIn, bigSeed, bpsSeed, devSeed, feeSeed);
        _checkIn(c, pick);
    }

    /// forge-config: default.fuzz.runs = 50000
    function testFuzz_V210_bandCapOutWideDomain(
        uint256 stSeed,
        uint256 tickSeed,
        bool zeroIn,
        uint256 bigSeed,
        uint16 bpsSeed,
        uint256 devSeed,
        uint32 feeSeed,
        uint256 pick
    ) public {
        Case memory c = _case(stSeed % 4, tickSeed, zeroIn, bigSeed, bpsSeed, devSeed, feeSeed);
        _checkOut(c, pick);
    }

    /// @dev `caps` and `capsOut` never revert (their NatSpec): any word in every argument gives a status.
    /// forge-config: default.fuzz.runs = 50000
    function testFuzz_V210_capsNeverRevertOnRawInputs(
        uint256 x,
        uint256 y,
        uint32 fee,
        uint256 outCap,
        uint256 pm,
        int24 snap,
        bool zeroIn,
        uint16 bps,
        uint8 shape
    ) public pure {
        // Half the runs squeeze the reserves to the edge cases the raw words almost never hit.
        if (shape % 4 == 0) (x, y) = (1 + x % 3, y % (2 ** 128));
        else if (shape % 4 == 1) (x, y) = (x % (2 ** 128), 1 + y % 3);
        else if (shape % 4 == 2) (x, y) = (2 ** 128 - 1 - x % 3, 2 ** 128 - 1 - y % 3);
        snap = int24(bound(int256(snap), TickMath.MIN_TICK, TickMath.MAX_TICK));
        // `bandBps` in the template's domain: `BandGuardV2._validate` refuses 0 and above 10,000 and `register` rebuilds the
        // order through it, so no registered maker has another value (see the pinned test below).
        bps = uint16(bound(bps, 1, 10_000));
        // `outCap` is `MakerVenue.real`, which is `min(virtual y, wallet, allowance)`: never above `y` (`MakerVenue.sol:77-80`).
        outCap = outCap < y ? outCap : y;
        MakerVenue.caps(x, y, fee, outCap, pm, snap, zeroIn, bps);
        MakerVenue.capsOut(x, y, fee, outCap, pm, snap, zeroIn, bps);
    }

    /// @dev PINNED: `caps` and `capsOut` are "never revert" only for `bandBps` in the template's domain 1 to 10,000. Above
    ///      it `_band` underflows (`ref - lim`). Unreachable on chain: `register` rebuilds the order through
    ///      `BandGuardV2.build`, whose `_validate` rejects it. Recorded in THREATS.md.
    function capsHarness(uint16 bps, bool exactIn) external pure {
        if (exactIn) MakerVenue.caps(1e18, 1e18, 0, 1e18, type(uint256).max, 0, true, bps);
        else MakerVenue.capsOut(1e18, 1e18, 0, 1e18, type(uint256).max, 0, true, bps);
    }

    function capsRawHarness(uint256 outCap) external pure {
        MakerVenue.caps(2 ** 128 - 1, 2 ** 128 - 1, 0, outCap, type(uint256).max, 0, true, 10_000);
    }

    function test_V210_pinned_bandBpsAboveTemplateDomainPanics() public {
        vm.expectRevert(stdError.arithmeticError);
        this.capsHarness(10_001, true);
        vm.expectRevert(stdError.arithmeticError);
        this.capsHarness(10_001, false);
        // `outCap + 1` overflows only for outCap = 2^256 - 1, which `real` (<= the virtual balance y) never gives.
        vm.expectRevert(stdError.arithmeticError);
        this.capsRawHarness(type(uint256).max);
        this.capsHarness(10_000, true);
        this.capsHarness(10_000, false);
    }

    // ---------------------------------------------------------------- non-vacuity

    /// @dev Fixed seeds for one mode and stratum, both directions: how many cases produced real caps with every fill
    ///      passing. One test per cell keeps each test's memory small. Before this file the V206/V208 domain was
    ///      |tick| <= 300,000, so strata 1 to 3 had 0% coverage.
    function _cell(uint256 mode, uint256 st) internal {
        uint256 perCell = 300;
        for (uint256 dir; dir < 2; dir++) {
            uint256 okN;
            uint256 tinyN;
            for (uint256 i; i < perCell; i++) {
                uint256 r = uint256(keccak256(abi.encode(mode, st, dir, i)));
                Case memory c = _case(
                    st,
                    r,
                    dir == 0,
                    uint256(keccak256(abi.encode(r, 1))),
                    uint16(uint256(keccak256(abi.encode(r, 2)))),
                    uint256(keccak256(abi.encode(r, 3))),
                    uint32(uint256(keccak256(abi.encode(r, 4))))
                );
                bool got = mode == 0 ? _checkIn(c, r) : _checkOut(c, r);
                if (got) {
                    okN++;
                    if (c.x <= 3) tinyN++;
                }
            }
            emit log_named_string(
                string.concat(
                    mode == 0 ? "exact-in " : "exact-out ",
                    "stratum ",
                    vm.toString(st),
                    dir == 0 ? " token0 in" : " token1 in"
                ),
                string.concat(
                    vm.toString(okN), " of ", vm.toString(perCell), " gave caps, ", vm.toString(tinyN), " tiny makers"
                )
            );
            assertGt(okN, 10, "a stratum x mode x direction produced (almost) no caps: the fuzz would be vacuous");
        }
    }

    function test_V210_coverageInStratum0() public {
        _cell(0, 0);
        _cell(1, 0);
    }

    function test_V210_coverageInStratum1() public {
        _cell(0, 1);
        _cell(1, 1);
    }

    function test_V210_coverageInStratum2() public {
        _cell(0, 2);
        _cell(1, 2);
    }

    function test_V210_coverageInStratum3() public {
        _cell(0, 3);
        _cell(1, 3);
    }
}
