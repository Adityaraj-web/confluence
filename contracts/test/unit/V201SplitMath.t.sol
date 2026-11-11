// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SplitMath} from "../../src/libraries/SplitMath.sol";
import {Vectors} from "../base/Vectors.sol";

/// @dev External wrapper so gas can be measured around one call. Test-only.
contract SplitMathHarness {
    function measureIn(SplitMath.Venue[] memory v, uint256 amount)
        external
        view
        returns (uint256 gasUsed, uint256[] memory a)
    {
        uint256 g = gasleft();
        a = SplitMath.solveExactIn(v, amount);
        gasUsed = g - gasleft();
    }

    function measureOut(SplitMath.Venue[] memory v, uint256 amount)
        external
        view
        returns (uint256 gasUsed, uint256[] memory b)
    {
        uint256 g = gasleft();
        b = SplitMath.solveExactOut(v, amount);
        gasUsed = g - gasleft();
    }
}

/// @notice V2-01 acceptance: SplitMath against the V2-00 vectors and its fuzzed properties.
/// @dev Index 0 is the pool everywhere (it takes the remainder). Tolerances and fuzz domains are recorded in D-29.
contract V201SplitMathTest is Test {
    uint256 internal constant E9 = 1e9;
    uint256 internal constant MAX_AMOUNT = type(uint128).max;
    uint256 internal constant NONE = type(uint256).max;

    /// @dev The worst of the three 4-venue solves must stay under it. Measured (via_ir, optimizer 700): exact in 48,726;
    ///      exact out 43,730; exact in with one cap binding (two passes) 62,938. Ceiling = worst + about 11% (PROGRESS).
    uint256 internal constant GAS_CEILING_4V = 70_000;

    // Fuzz domains (D-29).
    uint8 internal constant GENERAL = 0; // anything inside the envelope, some unusable venues
    uint8 internal constant COMPARABLE = 1; // reserves >= 1e9, y/x in [1e-3, 1e3]
    uint8 internal constant WIDE = 2; // reserves in [1e9, 2^112], any price
    uint8 internal constant ANYPRICE = 3; // reserves in [1, 2^128), any price

    SplitMathHarness internal harness;

    function setUp() public {
        harness = new SplitMathHarness();
    }

    // =====================================================================================================
    // Vectors
    // =====================================================================================================

    function test_V201_matchesVectors() public view {
        uint256 checked = _checkFile(Vectors.SPLIT_2V, true) + _checkFile(Vectors.SPLIT_3V, true)
            + _checkFile(Vectors.SPLIT_CAPS, true);
        assertEq(checked, 26, "exact-in vector cases checked");
    }

    function test_V201_exactOutMatchesVectors() public view {
        uint256 checked = _checkFile(Vectors.SPLIT_2V, false) + _checkFile(Vectors.SPLIT_3V, false)
            + _checkFile(Vectors.SPLIT_CAPS, false);
        assertEq(checked, 26, "exact-out vector cases checked");
    }

    /// @dev The v1 demo pool (its integer segment, capped at `capIn`) and Priya: decimals 6 vs 18 both ways.
    function test_V201_matchesV1DemoClosedForm() public view {
        string memory json = Vectors.read(Vectors.V1_DEMO);
        uint256 n = Vectors.count(json);
        for (uint256 i; i < n; i++) {
            Vectors.V1Case memory c = Vectors.v1Case(json, i);
            SplitMath.Venue[] memory v = new SplitMath.Venue[](2);
            v[0] = _venue(c.poolVenue);
            v[1] = _venue(c.priya);
            uint256[] memory a = SplitMath.solveExactIn(v, c.amount);
            assertEq(a.length, 2, c.name);
            assertEq(a[0] + a[1], c.amount, string.concat(c.name, ": sum"));
            assertApproxEqAbs(a[1], c.allocPriya, c.amount / E9, string.concat(c.name, ": Priya's share"));
            console2.log(c.name, "Priya", a[1]);
            console2.log("  vector", c.allocPriya);
        }
    }

    // =====================================================================================================
    // Fuzzed properties
    // =====================================================================================================

    function testFuzz_V201_sumEqualsAmount(uint256 seed, uint256 amountSeed) public pure {
        SplitMath.Venue[] memory v = _venues(seed, 1 + seed % 8, GENERAL);
        _randomCaps(v, seed, MAX_AMOUNT);
        uint256 amount = amountSeed % 16 == 0 ? 0 : _logUniform(amountSeed, 1, MAX_AMOUNT);

        uint256[] memory a = SplitMath.solveExactIn(v, amount);
        assertEq(a.length, v.length, "in: length");
        assertEq(_sum(a), amount, "in: parts do not sum to the amount");

        uint256[] memory b = SplitMath.solveExactOut(v, amount);
        assertEq(b.length, v.length, "out: length");
        assertEq(_sum(b), amount, "out: parts do not sum to the amount");
    }

    function testFuzz_V201_respectsCaps(uint256 seed, uint256 amountSeed) public pure {
        uint256 n = 2 + seed % 7;
        SplitMath.Venue[] memory v = _venues(seed, n, COMPARABLE);
        for (uint256 mode; mode < 2; mode++) {
            bool exactIn = mode == 0;
            uint256 amount = exactIn
                ? _logUniform(amountSeed, 1, _min(MAX_AMOUNT, _sumX(v)))
                : _logUniform(amountSeed, 1, _sumY(v) / 2);
            _clearCaps(v);
            uint256[] memory free = _solve(v, amount, exactIn);
            // Cap some makers at a fraction (0 to 1.5) of their uncapped share; the pool stays uncapped.
            for (uint256 i = 1; i < n; i++) {
                uint256 w = _word(seed, i, 7 + mode);
                if (w % 3 != 0) v[i].cap = FullMath.mulDiv(free[i], w % 1501, 1000);
            }
            uint256[] memory a = _solve(v, amount, exactIn);
            assertEq(_sum(a), amount, "sum");
            for (uint256 i = 1; i < n; i++) {
                assertLe(a[i], v[i].cap, "maker above its cap");
                if (free[i] > v[i].cap) assertEq(a[i], v[i].cap, "a maker over its cap must be pinned at it");
            }
        }
    }

    /// @dev Comparable-price venues: the spec's literal `v.length` wei (D-29).
    function testFuzz_V201_neverWorseThanAnySingleVenue(uint256 seed, uint256 amountSeed) public pure {
        _neverWorse(seed, amountSeed, COMPARABLE);
    }

    /// @dev The whole envelope: `v.length` wei plus `v.length` wei of the allocated token at the highest marginal
    ///      rate a venue reaches (D-29). One input wei can buy 1e12 output wei (USDC to MUMB).
    function testFuzz_V201_neverWorseThanAnySingleVenueAnyPrice(uint256 seed, uint256 amountSeed) public pure {
        _neverWorse(seed, amountSeed, ANYPRICE);
    }

    function testFuzz_V201_equalMarginals(uint256 seed, uint256 amountSeed) public pure {
        uint256 n = 1 + seed % 8;
        SplitMath.Venue[] memory v = _venues(seed, n, WIDE);
        for (uint256 mode; mode < 2; mode++) {
            bool exactIn = mode == 0;
            uint256 amount = exactIn
                ? _logUniform(amountSeed, 1, _min(MAX_AMOUNT, _sumX(v)))
                : _logUniform(amountSeed, 1, _sumY(v) / 2);
            _clearCaps(v);
            _randomCaps(v, seed ^ mode, amount);
            uint256[] memory a = _solve(v, amount, exactIn);
            assertEq(_sum(a), amount, "sum");
            _checkMarginals(v, a, exactIn);
        }
    }

    function testFuzz_V201_neverReverts(uint256 seed, uint8 nRaw, uint256 amountSeed) public pure {
        uint256 n = nRaw % 11;
        SplitMath.Venue[] memory v = new SplitMath.Venue[](n);
        bool outside = n > 8;
        for (uint256 i; i < n; i++) {
            v[i].x = _edgy(_word(seed, i, 1));
            v[i].y = _edgy(_word(seed, i, 2));
            v[i].feeE9 = uint32(_word(seed, i, 3));
            v[i].cap = _edgy(_word(seed, i, 4));
            if (v[i].x > MAX_AMOUNT || v[i].y > MAX_AMOUNT) outside = true;
        }
        uint256 amount = _edgy(amountSeed);
        if (amount > MAX_AMOUNT) outside = true;

        for (uint256 mode; mode < 2; mode++) {
            uint256[] memory a = _solve(v, amount, mode == 0);
            assertEq(a.length, n, "length");
            if (n == 0) continue;
            assertEq(_sum(a), amount, "sum");
            if (outside) {
                assertEq(a[0], amount, "outside the envelope: the pool takes everything");
            }
        }
    }

    /// @dev Each envelope edge on its own, with ordinary venues that would otherwise get a share (D-29). The fuzz above
    ///      rarely draws an out-of-range amount together with usable in-range venues; a mutation dropping the amount
    ///      check survived it.
    function test_V201_outsideEnvelopeIsPoolOnly() public pure {
        SplitMath.Venue[] memory v = new SplitMath.Venue[](3);
        v[0] = SplitMath.Venue(10_000e18, 10_000e18, 3_000_000, NONE);
        v[1] = SplitMath.Venue(10_000e18, 10_100e18, 500_000, NONE);
        v[2] = SplitMath.Venue(10_000e18, 10_050e18, 1_000_000, NONE);
        // Control: inside the envelope the makers are used.
        uint256[] memory a = SplitMath.solveExactIn(v, 1_000e18);
        assertGt(a[1], 0, "control: maker 1 used");

        _assertPoolOnly(v, MAX_AMOUNT + 1, "amount = 2^128");
        _assertPoolOnly(v, type(uint256).max, "amount = max");
        v[2].x = MAX_AMOUNT + 1;
        _assertPoolOnly(v, 1_000e18, "x = 2^128");
        v[2].x = 10_000e18;
        v[1].y = MAX_AMOUNT + 1;
        _assertPoolOnly(v, 1_000e18, "y = 2^128");
        v[1].y = 10_100e18;

        SplitMath.Venue[] memory nine = new SplitMath.Venue[](9);
        for (uint256 i; i < 9; i++) {
            nine[i] = v[i % 3];
        }
        _assertPoolOnly(nine, 1_000e18, "9 venues");
    }

    function _assertPoolOnly(SplitMath.Venue[] memory v, uint256 amount, string memory ctx) internal pure {
        for (uint256 mode; mode < 2; mode++) {
            uint256[] memory a = _solve(v, amount, mode == 0);
            assertEq(a.length, v.length, ctx);
            assertEq(a[0], amount, string.concat(ctx, ": pool-only"));
            for (uint256 i = 1; i < a.length; i++) {
                assertEq(a[i], 0, string.concat(ctx, ": maker must get zero"));
            }
        }
    }

    function testFuzz_V201_sqrtIsFloor(uint256 aSeed, uint256 bSeed, uint256 dSeed) public pure {
        uint256 d = _logUniform(dSeed, 1, 1 << 30);
        uint256 a = _logUniform(aSeed, d, 1 << 218);
        uint256 b = _logUniform(bSeed, 1, MAX_AMOUNT);
        uint256 z = SplitMath.sqrtMulDiv(a, b, d);
        // z^2 <= floor(ab/d) < (z+1)^2  <=>  z^2 d <= ab < (z+1)^2 d
        (uint256 abHi, uint256 abLo) = Math.mul512(a, b);
        (uint256 loHi, uint256 loLo) = Math.mul512(z * d, z);
        (uint256 upHi, uint256 upLo) = Math.mul512((z + 1) * d, z + 1);
        assertTrue(_le512(loHi, loLo, abHi, abLo), "z too big");
        assertTrue(_lt512(abHi, abLo, upHi, upLo), "z too small");
    }

    // =====================================================================================================
    // Gas
    // =====================================================================================================

    function test_V201_gasCeiling() public view {
        SplitMath.Venue[] memory v = new SplitMath.Venue[](4);
        v[0] = SplitMath.Venue(10_000e18, 10_050e18, 3_000_000, NONE);
        v[1] = SplitMath.Venue(8_000e18, 8_020e18, 500_000, NONE);
        v[2] = SplitMath.Venue(12_000e18, 12_000e18, 1_000_000, NONE);
        v[3] = SplitMath.Venue(5_000e18, 5_030e18, 3_000_000, NONE);

        (uint256 gasIn, uint256[] memory a) = harness.measureIn(v, 1_000e18);
        _assertAllActive(a, 1_000e18, "in");
        (uint256 gasOut, uint256[] memory b) = harness.measureOut(v, 1_000e18);
        _assertAllActive(b, 1_000e18, "out");

        uint256 cap = a[2] * 4 / 10;
        v[2].cap = cap;
        (uint256 gasCap, uint256[] memory c) = harness.measureIn(v, 1_000e18);
        assertEq(c[2], cap, "capped: venue 2 pinned at its cap");
        assertEq(_sum(c), 1_000e18, "capped: sum");

        console2.log("gas exact in, 4 venues", gasIn);
        console2.log("gas exact out, 4 venues", gasOut);
        console2.log("gas exact in, 4 venues, one cap binding", gasCap);
        uint256 worst = Math.max(gasIn, Math.max(gasOut, gasCap));
        assertLe(worst, GAS_CEILING_4V, "4-venue solve above the gas ceiling");
    }

    // =====================================================================================================
    // Vector helpers
    // =====================================================================================================

    function _checkFile(string memory file, bool exactIn) internal view returns (uint256 checked) {
        string memory json = Vectors.read(file);
        uint256 n = Vectors.count(json);
        uint256 maxDev;
        for (uint256 i; i < n; i++) {
            Vectors.Split memory s = Vectors.split(json, i);
            if (s.exactIn != exactIn) continue;
            SplitMath.Venue[] memory v = new SplitMath.Venue[](s.venues.length);
            for (uint256 j; j < v.length; j++) {
                v[j] = _venue(s.venues[j]);
            }
            uint256[] memory a = _solve(v, s.amount, exactIn);
            assertEq(a.length, v.length, s.name);
            assertEq(_sum(a), s.amount, string.concat(s.name, ": sum"));
            uint256 total;
            for (uint256 j; j < v.length; j++) {
                string memory ctx = string.concat(s.name, " venue ", vm.toString(j));
                if (s.alloc[j] == 0) assertEq(a[j], 0, string.concat(ctx, ": unused venue must get zero"));
                assertApproxEqAbs(a[j], s.alloc[j], s.amount / E9, ctx);
                uint256 dev = a[j] > s.alloc[j] ? a[j] - s.alloc[j] : s.alloc[j] - a[j];
                if (dev > maxDev) maxDev = dev;
                if (a[j] > 0) total += exactIn ? _cpOutInt(v[j], a[j]) : _cpInInt(v[j], a[j]);
            }
            assertApproxEqRel(total, s.totalInt, 1e9, string.concat(s.name, ": total"));
            checked++;
        }
        console2.log(file, exactIn ? "exact in, max deviation (wei)" : "exact out, max deviation (wei)", maxDev);
    }

    function _venue(Vectors.VenueV memory w) internal pure returns (SplitMath.Venue memory) {
        return SplitMath.Venue(w.x, w.y, w.feeE9, w.cap);
    }

    /// @dev SwapVM exact in: flat fee rounded up on the input, then XYC rounded down (Fee.sol:89, XYCSwap.sol:22).
    function _cpOutInt(SplitMath.Venue memory v, uint256 a) internal pure returns (uint256) {
        uint256 net = a - Math.ceilDiv(a * v.feeE9, E9);
        return FullMath.mulDiv(net, v.y, v.x + net);
    }

    /// @dev SwapVM exact out: XYC input rounded up, then the fee grossed up, rounded up (XYCSwap.sol:28, Fee.sol:95).
    function _cpInInt(SplitMath.Venue memory v, uint256 b) internal pure returns (uint256) {
        uint256 net = FullMath.mulDivRoundingUp(b, v.x, v.y - b);
        return FullMath.mulDivRoundingUp(net, E9, E9 - v.feeE9);
    }

    // =====================================================================================================
    // Property helpers
    // =====================================================================================================

    function _neverWorse(uint256 seed, uint256 amountSeed, uint8 domain) internal pure {
        uint256 n = 1 + seed % 8;
        SplitMath.Venue[] memory v = _venues(seed, n, domain);

        // Exact in.
        uint256 amount = _logUniform(amountSeed, 1, _min(MAX_AMOUNT, _sumX(v)));
        _randomCaps(v, seed, 2 * amount);
        uint256[] memory a = SplitMath.solveExactIn(v, amount);
        uint256 split;
        for (uint256 i; i < n; i++) {
            split += _outFloor(v[i], a[i]);
        }
        uint256 best;
        uint256 slack = n;
        for (uint256 i; i < n; i++) {
            if (i == 0 || v[i].cap >= amount) best = Math.max(best, _outFloor(v[i], amount));
            if (domain == ANYPRICE) {
                uint256 rate = FullMath.mulDivRoundingUp(E9 - v[i].feeE9, v[i].y, v[i].x * E9);
                slack = Math.max(slack, n + n * rate);
            }
        }
        assertGe(split + slack, best, "in: split worse than a single venue");

        // Exact out: only amounts some single venue can give.
        _clearCaps(v);
        uint256 maxY;
        for (uint256 i; i < n; i++) {
            maxY = Math.max(maxY, v[i].y);
        }
        if (maxY < 2) return;
        amount = _logUniform(amountSeed >> 1, 1, maxY - 1);
        _randomCaps(v, seed >> 1, 2 * amount);
        uint256[] memory b = SplitMath.solveExactOut(v, amount);
        uint256 bestCost = NONE;
        for (uint256 i; i < n; i++) {
            if (amount < v[i].y && (i == 0 || v[i].cap >= amount)) {
                bestCost = Math.min(bestCost, _inCeil(v[i], amount));
            }
        }
        if (bestCost == NONE) return;
        if (b[0] >= v[0].y) {
            // The pool's floored remainder reached its own reserve. Happens when the exact optimum leaves the pool
            // under `n` wei of reserve: a dust-sized pool, or a trade that nearly drains every venue (D-29). The
            // remainder rule puts it at most `n` wei past that; a plain curve cannot price it, so no cost check.
            assertLe(b[0] - (v[0].y - 1), n, "out: pool remainder past its reserve by more than rounding");
            return;
        }
        uint256 cost;
        slack = n;
        for (uint256 i; i < n; i++) {
            assertLt(b[i], v[i].y, "out: a venue asked for its whole reserve");
            cost += _inCeil(v[i], b[i]);
            if (domain == ANYPRICE) slack = Math.max(slack, _satAdd(n, _satMul(n, _marginalCost(v[i], b[i] + n))));
        }
        assertLe(cost, _satAdd(bestCost, slack), "out: split costs more than a single venue");
    }

    /// @dev Exact-in: (x + g a) / sqrt(g x y) is the same for every free active venue (equal marginals).
    ///      Exact-out: (y - b) sqrt(g) / sqrt(x y) is. 1e-6 on the marginal is 5e-7 on these (marginal ~ 1/h^2).
    function _checkMarginals(SplitMath.Venue[] memory v, uint256[] memory a, bool exactIn) internal pure {
        uint256 n = v.length;
        uint256 ref;
        for (uint256 i; i < n; i++) {
            if (_isFreeActive(v, a, i, exactIn)) {
                ref = _h(v[i], a[i], exactIn);
                break;
            }
        }
        if (ref == 0) return; // every venue pinned at its cap
        for (uint256 i; i < n; i++) {
            if (_isFreeActive(v, a, i, exactIn)) {
                assertApproxEqRel(_h(v[i], a[i], exactIn), ref, 5e11, "marginals differ");
            } else if (a[i] <= (i == 0 ? n : 0) && v[i].cap > 0) {
                // Unused (or only the pool's rounding dust): it must not start better than the level.
                uint256 h0 = _h(v[i], 0, exactIn);
                if (exactIn) assertGe(h0 * 1e18, ref * (1e18 - 5e11), "an unused venue starts better (in)");
                else assertLe(h0 * 1e18, ref * (1e18 + 5e11), "an unused venue starts better (out)");
            }
        }
    }

    function _isFreeActive(SplitMath.Venue[] memory v, uint256[] memory a, uint256 i, bool exactIn)
        internal
        pure
        returns (bool)
    {
        if (i == 0 ? a[0] <= v.length : a[i] == 0) return false;
        if (i > 0 && a[i] >= v[i].cap) return false;
        if (!exactIn) {
            // The pool past its own reserve (caps left a remainder the free venues could not cover): no marginal (D-29).
            if (a[i] >= v[i].y) return false;
            // Below 1e9 wei left in the reserve, one wei moves the marginal by more than 1e-6.
            if (v[i].y - a[i] < 1e9) return false;
        }
        return true;
    }

    function _h(SplitMath.Venue memory v, uint256 a, bool exactIn) internal pure returns (uint256) {
        uint256 g = E9 - v.feeE9;
        if (exactIn) return FullMath.mulDiv(v.x * E9 + g * a, 1e18, Math.sqrt(g * v.x * v.y));
        return FullMath.mulDiv((v.y - a) * Math.sqrt(g * 1e18), 1e18, Math.sqrt(v.x * v.y * (1 << 30)));
    }

    function _assertAllActive(uint256[] memory a, uint256 amount, string memory ctx) internal pure {
        assertEq(_sum(a), amount, string.concat(ctx, ": sum"));
        for (uint256 i; i < a.length; i++) {
            assertGt(a[i], 0, string.concat(ctx, ": every venue should be used"));
        }
    }

    /// @dev Exact curve output, one floor: floor(y g a / (x 1e9 + g a)).
    function _outFloor(SplitMath.Venue memory v, uint256 a) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 g = E9 - v.feeE9;
        return FullMath.mulDiv(v.y * g, a, v.x * E9 + g * a);
    }

    /// @dev Exact curve input, one ceil: ceil(x 1e9 b / (g (y - b))).
    function _inCeil(SplitMath.Venue memory v, uint256 b) internal pure returns (uint256) {
        if (b == 0) return 0;
        uint256 g = E9 - v.feeE9;
        return FullMath.mulDivRoundingUp(v.x * E9, b, g * (v.y - b));
    }

    /// @dev Marginal input per output wei at `b` (capped below the reserve), rounded up, saturating.
    function _marginalCost(SplitMath.Venue memory v, uint256 b) internal pure returns (uint256) {
        if (b >= v.y) b = v.y - 1;
        uint256 left = v.y - b;
        uint256 g = E9 - v.feeE9;
        uint256 t = Math.ceilDiv(v.x * E9, g); // x / gamma, rounded up
        if (t > NONE / v.y) return NONE;
        return Math.ceilDiv(Math.ceilDiv(t * v.y, left), left);
    }

    // =====================================================================================================
    // Generators
    // =====================================================================================================

    function _venues(uint256 seed, uint256 n, uint8 domain) internal pure returns (SplitMath.Venue[] memory v) {
        v = new SplitMath.Venue[](n);
        for (uint256 i; i < n; i++) {
            uint256 wx = _word(seed, i, 1);
            uint256 wy = _word(seed, i, 2);
            uint256 wf = _word(seed, i, 3);
            if (domain == GENERAL) {
                v[i].x = wx % 16 == 1 ? 0 : _logUniform(wx, 1, MAX_AMOUNT);
                v[i].y = wy % 16 == 1 ? 0 : _logUniform(wy, 1, MAX_AMOUNT);
                v[i].feeE9 = wf % 8 == 0 ? uint32(E9 + wf % (type(uint32).max - E9)) : uint32(wf % 1e8);
            } else if (domain == COMPARABLE) {
                v[i].x = _logUniform(wx, 1e9, 1 << 112);
                v[i].y = FullMath.mulDiv(v[i].x, _logUniform(wy, 1e15, 1e21), 1e18);
                v[i].feeE9 = uint32(wf % 1e8);
            } else if (domain == WIDE) {
                v[i].x = _logUniform(wx, 1e9, 1 << 112);
                v[i].y = _logUniform(wy, 1e9, 1 << 112);
                v[i].feeE9 = uint32(wf % 1e8);
            } else {
                v[i].x = _logUniform(wx, 1, MAX_AMOUNT);
                v[i].y = _logUniform(wy, 1, MAX_AMOUNT);
                v[i].feeE9 = uint32(wf % 5e8);
            }
            v[i].cap = NONE;
        }
    }

    /// @dev Half the makers get a cap in [1, maxCap]; the pool is never capped.
    function _randomCaps(SplitMath.Venue[] memory v, uint256 seed, uint256 maxCap) internal pure {
        if (maxCap == 0) return;
        for (uint256 i = 1; i < v.length; i++) {
            uint256 w = _word(seed, i, 5);
            v[i].cap = w % 2 == 0 ? NONE : _logUniform(w >> 1, 1, maxCap);
        }
    }

    function _clearCaps(SplitMath.Venue[] memory v) internal pure {
        for (uint256 i; i < v.length; i++) {
            v[i].cap = NONE;
        }
    }

    /// @dev Values biased to the envelope edge: 2^128 +- 2, small, raw, or log-uniform below 2^128.
    function _edgy(uint256 w) internal pure returns (uint256) {
        uint256 k = w % 5;
        if (k == 0) return (1 << 128) - 2 + (w >> 8) % 5;
        if (k == 1) return (w >> 8) % 1000;
        if (k == 2) return w;
        return _logUniform(w >> 8, 1, MAX_AMOUNT);
    }

    /// @dev A value in [lo, hi] whose bit length is uniform over the range's bit lengths.
    function _logUniform(uint256 w, uint256 lo, uint256 hi) internal pure returns (uint256 r) {
        if (hi <= lo) return lo;
        uint256 loBits = Math.log2(lo);
        uint256 hiBits = Math.log2(hi);
        uint256 bits = loBits + w % (hiBits - loBits + 1);
        uint256 mantissa = uint256(keccak256(abi.encode(w)));
        r = bits == 0 ? 1 : (1 << bits) | (mantissa & ((1 << bits) - 1));
        if (r < lo) r = lo;
        if (r > hi) r = hi;
    }

    function _word(uint256 seed, uint256 i, uint256 tag) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i, tag)));
    }

    // =====================================================================================================
    // Small maths
    // =====================================================================================================

    function _solve(SplitMath.Venue[] memory v, uint256 amount, bool exactIn) internal pure returns (uint256[] memory) {
        return exactIn ? SplitMath.solveExactIn(v, amount) : SplitMath.solveExactOut(v, amount);
    }

    function _sum(uint256[] memory a) internal pure returns (uint256 s) {
        for (uint256 i; i < a.length; i++) {
            s += a[i];
        }
    }

    function _sumX(SplitMath.Venue[] memory v) internal pure returns (uint256 s) {
        for (uint256 i; i < v.length; i++) {
            s += v[i].x;
        }
    }

    function _sumY(SplitMath.Venue[] memory v) internal pure returns (uint256 s) {
        for (uint256 i; i < v.length; i++) {
            s += v[i].y;
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _satAdd(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            uint256 c = a + b;
            return c < a ? NONE : c;
        }
    }

    function _satMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        return b > NONE / a ? NONE : a * b;
    }

    function _le512(uint256 aHi, uint256 aLo, uint256 bHi, uint256 bLo) internal pure returns (bool) {
        return aHi < bHi || (aHi == bHi && aLo <= bLo);
    }

    function _lt512(uint256 aHi, uint256 aLo, uint256 bHi, uint256 bLo) internal pure returns (bool) {
        return aHi < bHi || (aHi == bHi && aLo < bLo);
    }
}
