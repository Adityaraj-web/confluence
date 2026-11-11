// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SplitMath
/// @notice Best split of one trade across up to `MAX_VENUES` constant-product venues (ARCHITECTURE-v2 section 3),
///         exact input and exact output, with a cap per venue. Pure: no storage, no external calls. Never reverts.
/// @dev A venue's curve is out(a) = y g a / (x + g a), g = 1 - fee. At the best split every used venue that is not at
///      its cap has the same marginal rate. Closed form for an active set S (k = sqrt(g x y), c = sqrt(x y / g)):
///        exact in,  amount A:  L = (A + sum x/g) / (sum k/g),   a_i = (k_i L - x_i) / g_i
///        exact out, amount B:  w = (sum y - B) / (sum c),       b_i = y_i - c_i w
///      Active set: venues sorted by starting rate g y / x (ties by index), added while the newcomer's share is
///      positive. Caps: every venue over its cap is pinned at it and the rest is solved again (at most `v.length`
///      passes).
///
///      Overflow envelope: every reserve (`x`, `y`) and the amount are below 2^128, and `v.length <= MAX_VENUES`.
///      Outside it the result is pool-only: index 0 gets the whole amount, every maker zero. Inside it no
///      intermediate value overflows (bounds next to each product below).
///
///      Integer policy (D-28, D-29), the same as `reference/waterfill.py` integer mode: k and c are integer square
///      roots (floor) of `g 1e9 x y` and `x y 1e27 / g`, so they are exact to the reference. Every other rounding
///      makes a share no larger than its exact value, so the makers never sum past the amount. Maker amounts
///      (index >= 1) are those floored shares; index 0, by convention the pool, takes the remainder, so the parts sum
///      exactly to the amount. Maker caps are hard; index 0 may end past its own cap (V2-02 reads that as "cross
///      into the next range").
///
///      Degenerate input, never a revert: an empty array gives an empty result; amount 0 gives zeros; a venue with
///      x = 0, y = 0 or a fee of 100% or more gets zero; when the venues still free cannot fill what is left
///      (no usable venue, or an exact output at or above their reserves), they get zero, venues already pinned keep
///      their caps, and the pool takes the rest.
library SplitMath {
    /// @notice A constant-product venue: reserves `x` (input token) and `y` (output token), a flat fee on the input
    ///         (`feeE9`, 1e9 = 100%, SwapVM's scale) and a cap. `cap` is in input units for exact input and in output
    ///         units for exact output; `type(uint256).max` means none.
    struct Venue {
        uint256 x;
        uint256 y;
        uint32 feeE9;
        uint256 cap;
    }

    /// @notice Most venues one solve takes (V2-01). Bounds every loop over venues and every pass.
    uint256 internal constant MAX_VENUES = 8;

    /// @notice Fee scale: 1e9 = 100% (SwapVM `BPS`, swap-vm/src/instructions/Fee.sol:17).
    uint256 internal constant FEE_SCALE = 1e9;

    /// @notice Largest reserve or amount inside the overflow envelope (2^128 - 1).
    uint256 internal constant MAX_AMOUNT = type(uint128).max;

    /// @notice Bound on Newton steps in `sqrtMulDiv`. The seed is at most 4x the root, which needs about 8 steps to
    ///         get within 1 of a root below 2^175, and one or two more to stop; 16 leaves room.
    uint256 internal constant SQRT_MAX_STEPS = 16;

    /// @dev FEE_SCALE^3, the scale of `c` squared for exact output.
    uint256 private constant FEE_SCALE_CUBED = 1e27;

    /// @dev Extra precision for the exact-in level (2^64).
    uint256 private constant Q = 1 << 64;

    /// @notice Best split of `amountIn` input. `a[i]` is the input venue `i` takes; the parts sum to `amountIn`.
    function solveExactIn(Venue[] memory v, uint256 amountIn) internal pure returns (uint256[] memory a) {
        return _solve(v, amountIn, true);
    }

    /// @notice Cheapest split for `amountOut` output. `b[i]` is the output venue `i` gives; the parts sum to `amountOut`.
    function solveExactOut(Venue[] memory v, uint256 amountOut) internal pure returns (uint256[] memory b) {
        return _solve(v, amountOut, false);
    }

    /// @notice floor(sqrt(floor(a * b / d))), the product taken in 512 bits.
    /// @dev Newton's method from above: z <- (z + floor(N / z)) / 2 with floor(N / z) = mulDiv(a, b, d z), stopping
    ///      when z stops falling; from any start >= floor(sqrt(N)) this ends at floor(sqrt(N)). The seed
    ///      (sqrt(floor(a/d)) + 1)(sqrt(b) + 1) is >= sqrt(N), and at most 4x it when a >= d (both callers: a/d >= 1e18).
    ///      Needs d z < 2^256: callers pass d < 2^30 and z < 2^175.
    function sqrtMulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256 z) {
        (uint256 hi, uint256 lo) = Math.mul512(a, b);
        if (hi == 0 && lo < d) return 0; // N = 0 (also a = 0 or b = 0)
        z = (Math.sqrt(a / d) + 1) * (Math.sqrt(b) + 1);
        for (uint256 i; i < SQRT_MAX_STEPS; i++) {
            uint256 next = (z + FullMath.mulDiv(a, b, d * z)) >> 1;
            if (next >= z) break;
            z = next;
        }
    }

    // ------------------------------------------------------------------------------------------------- solver

    /// @dev Per-solve working state. `g[i] == 0` marks an unusable venue.
    struct Work {
        uint256 n;
        bool exactIn;
        uint256[] g; // FEE_SCALE - feeE9
        uint256[] k; // exact in: floor(sqrt(g 1e9 x y)) = k 1e9; exact out: floor(sqrt(x y 1e27 / g)) = c 1e9
        uint256[] order; // usable venues, best starting rate first
        uint256 m; // number of usable venues
        bool[] pinned;
        uint256[] alloc;
    }

    function _solve(Venue[] memory v, uint256 amount, bool exactIn) private pure returns (uint256[] memory out) {
        uint256 n = v.length;
        out = new uint256[](n);
        if (n == 0 || amount == 0) return out;
        if (!_inEnvelope(v, amount)) {
            out[0] = amount;
            return out;
        }

        Work memory w = _prepare(v, exactIn);
        uint256 remaining = amount;
        for (uint256 pass; pass < n; pass++) {
            (uint256[] memory part, bool feasible) = exactIn ? _sharesIn(v, w, remaining) : _sharesOut(v, w, remaining);
            if (!feasible) break; // the free venues get nothing; the pool takes what is left
            bool over = false;
            for (uint256 j; j < w.m; j++) {
                uint256 i = w.order[j];
                if (!w.pinned[i] && part[i] > v[i].cap) {
                    over = true;
                    uint256 c = v[i].cap < remaining ? v[i].cap : remaining;
                    w.alloc[i] = c;
                    w.pinned[i] = true;
                    remaining -= c;
                }
            }
            if (!over) {
                for (uint256 j; j < w.m; j++) {
                    uint256 i = w.order[j];
                    if (!w.pinned[i]) w.alloc[i] = part[i];
                }
                break;
            }
        }

        // Makers keep their floored shares (clamped so they never pass the amount); index 0 takes the remainder.
        uint256 sum = 0;
        for (uint256 i = 1; i < n; i++) {
            uint256 x = w.alloc[i];
            if (x > amount - sum) x = amount - sum;
            out[i] = x;
            sum += x;
        }
        out[0] = amount - sum;
    }

    function _inEnvelope(Venue[] memory v, uint256 amount) private pure returns (bool) {
        if (v.length > MAX_VENUES || amount > MAX_AMOUNT) return false;
        for (uint256 i; i < v.length; i++) {
            if (v[i].x > MAX_AMOUNT || v[i].y > MAX_AMOUNT) return false;
        }
        return true;
    }

    /// @dev Fee factors, square roots (once per venue) and the rate order.
    function _prepare(Venue[] memory v, bool exactIn) private pure returns (Work memory w) {
        uint256 n = v.length;
        w.n = n;
        w.exactIn = exactIn;
        w.g = new uint256[](n);
        w.k = new uint256[](n);
        w.order = new uint256[](n);
        w.pinned = new bool[](n);
        w.alloc = new uint256[](n);
        for (uint256 i; i < n; i++) {
            if (v[i].x == 0 || v[i].y == 0 || v[i].feeE9 >= FEE_SCALE) continue;
            uint256 g = FEE_SCALE - v[i].feeE9;
            w.g[i] = g;
            // in:  g 1e9 x < 2^30 2^30 2^128 = 2^188; radicand < 2^316; k < 2^158.
            // out: x 1e27 < 2^128 2^90 = 2^218; radicand < 2^346 / g; c < 2^173.
            w.k[i] = exactIn
                ? sqrtMulDiv(g * FEE_SCALE * v[i].x, v[i].y, 1)
                : sqrtMulDiv(v[i].x * FEE_SCALE_CUBED, v[i].y, g);
            // Insertion by starting rate g y / x, best first; equal rates keep index order.
            uint256 p = w.m;
            for (uint256 s = 0; s < MAX_VENUES && p > 0; s++) {
                if (!_betterRate(v, w.g, i, w.order[p - 1])) break;
                w.order[p] = w.order[p - 1];
                p--;
            }
            w.order[p] = i;
            w.m++;
        }
    }

    /// @dev g_i y_i / x_i > g_j y_j / x_j, compared as 512-bit products (g y < 2^158, x < 2^128).
    function _betterRate(Venue[] memory v, uint256[] memory g, uint256 i, uint256 j) private pure returns (bool) {
        (uint256 aHi, uint256 aLo) = Math.mul512(g[i] * v[i].y, v[j].x);
        (uint256 bHi, uint256 bLo) = Math.mul512(g[j] * v[j].y, v[i].x);
        return aHi > bHi || (aHi == bHi && aLo > bLo);
    }

    /// @dev Exact-in shares of `amount` over the free usable venues, carried at 2^64 extra precision (`Q`) so the only
    ///      rounding that matters is the final floor, as in the reference:
    ///        S1 = sum floor(x 1e9 Q / g)  (= sum x/g, scaled by Q; floor)
    ///        S2 = sum ceil(k 1e9 Q / g)   (= sum k/g, scaled by 1e9 Q; ceil)
    ///        U  = floor(k Q (A Q + S1) / S2)  (= x + g a, scaled by Q)      a = floor((U - x Q) 1e9 / (g Q))
    ///      Floor on S1 and ceil on S2 make every share at most its exact value. With one venue the closed form is
    ///      exactly the amount, so that case skips the arithmetic.
    ///      Bounds: x 1e9 Q < 2^222, S1 < 2^225; k 1e9 Q < 2^252, S2 < 2^255; k Q <= S2, so U <= A Q + S1 < 2^226.
    function _sharesIn(Venue[] memory v, Work memory w, uint256 amount)
        private
        pure
        returns (uint256[] memory part, bool feasible)
    {
        part = new uint256[](w.n);
        uint256 aq = amount << 64;
        uint256 s1 = 0;
        uint256 s2 = 0;
        uint256 chosen = 0;
        uint256 first = 0;
        for (uint256 j; j < w.m; j++) {
            uint256 i = w.order[j];
            if (w.pinned[i]) continue;
            uint256 t1 = s1 + FullMath.mulDiv(v[i].x * FEE_SCALE, Q, w.g[i]);
            uint256 t2 = s2 + FullMath.mulDivRoundingUp(w.k[i] * FEE_SCALE, Q, w.g[i]);
            // The newcomer's share is positive iff U > x Q.
            if (FullMath.mulDiv(w.k[i] << 64, aq + t1, t2) <= v[i].x << 64) break;
            if (chosen == 0) first = i;
            s1 = t1;
            s2 = t2;
            chosen++;
        }
        if (chosen == 0) return (part, false);
        if (chosen == 1) {
            part[first] = amount;
            return (part, true);
        }
        uint256 seen = 0;
        for (uint256 j = 0; j < w.m && seen < chosen; j++) {
            uint256 i = w.order[j];
            if (w.pinned[i]) continue;
            seen++;
            uint256 u = FullMath.mulDiv(w.k[i] << 64, aq + s1, s2);
            uint256 xq = v[i].x << 64;
            if (u > xq) part[i] = FullMath.mulDiv(u - xq, FEE_SCALE, w.g[i] << 64);
        }
        return (part, true);
    }

    /// @dev Exact-out shares of `amount` over the free usable venues. T1 = sum y, T2 = sum c; the subtracted
    ///      c_i (T1 - B) / T2 is rounded up, so every share is at most its exact value.
    ///      Bounds: T2 < 8 2^173; c (T1 - B) < 2^173 2^131 inside mulDiv; the result <= T1 - B.
    function _sharesOut(Venue[] memory v, Work memory w, uint256 amount)
        private
        pure
        returns (uint256[] memory part, bool feasible)
    {
        part = new uint256[](w.n);
        uint256 t1 = 0;
        uint256 t2 = 0;
        uint256 chosen = 0;
        for (uint256 j; j < w.m; j++) {
            uint256 i = w.order[j];
            if (w.pinned[i]) continue;
            uint256 n1 = t1 + v[i].y;
            uint256 n2 = t2 + w.k[i];
            // While the reserves so far cannot cover the amount, the newcomer's share is above its reserve: positive.
            if (n1 > amount && FullMath.mulDivRoundingUp(w.k[i], n1 - amount, n2) >= v[i].y) break;
            t1 = n1;
            t2 = n2;
            chosen++;
        }
        if (chosen == 0 || t1 <= amount) return (part, false);
        uint256 seen = 0;
        for (uint256 j = 0; j < w.m && seen < chosen; j++) {
            uint256 i = w.order[j];
            if (w.pinned[i]) continue;
            seen++;
            uint256 d = FullMath.mulDivRoundingUp(w.k[i], t1 - amount, t2);
            if (d < v[i].y) part[i] = v[i].y - d;
        }
        return (part, true);
    }
}
