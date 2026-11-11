"""Closed-form split across constant-product venues (ARCHITECTURE-v2 section 3).

Every venue is out(a) = Y*g*a / (X + g*a). At the best split every used venue has the same marginal rate.

Exact input, amount A, active set S (k_i = sqrt(g_i X_i Y_i)):
    1/s = (A + sum_S X_j/g_j) / (sum_S k_j/g_j)        a_i = (k_i/s - X_i) / g_i

Exact output, amount B (c_i = sqrt(X_i Y_i / g_i)):
    w = (sum_S Y_j - B) / sum_S c_j                      b_i = Y_i - c_i * w

Active set: sort by starting rate g*Y/X, add venues while the newest one's share stays positive.
Caps: a venue over its cap is pinned at the cap and the rest is solved again (at most N passes).

Two arithmetics share the code:
* real:    Decimal, 60 digits.
* integer: the square root is an integer square root (floor); everything else is exact rational arithmetic;
           maker amounts (index >= 1) are floored and the pool (index 0) takes the remainder, so the parts
           sum exactly. This is the policy the Solidity library follows (V2-01).
"""

from decimal import Decimal
from fractions import Fraction
from math import isqrt
from typing import List, NamedTuple

import venues as vn
from venues import E9, Venue


class InfeasibleError(ValueError):
    """The venues cannot fill the amount (capacity or reserves too small)."""


# --------------------------------------------------------------------------- one pass, no caps


def _params(v, kind, integer):
    """(gamma, x, y, k) in the right number system. k = sqrt(g x y) for 'in', sqrt(x y / g) for 'out'."""
    if integer:
        x, y = int(v.x), int(v.y)
        g_int = E9 - v.fee_e9
        gam = Fraction(g_int, E9)
        if kind == "in":
            k = Fraction(isqrt(g_int * E9 * x * y), E9)
        else:
            k = Fraction(isqrt(x * y * 10**27 // g_int), E9)
        return gam, Fraction(x), Fraction(y), k
    gam = vn.gamma(v)
    x, y = Decimal(v.x), Decimal(v.y)
    k = (gam * x * y).sqrt() if kind == "in" else (x * y / gam).sqrt()
    return gam, x, y, k


def _uncapped(vs, total, kind, integer):
    """Allocations (same number system as the parameters) with no caps; unused venues get zero."""
    zero = Fraction(0) if integer else Decimal(0)
    n = len(vs)
    out = [zero] * n
    ps = {}
    for i, v in enumerate(vs):
        if v.x > 0 and v.y > 0:
            ps[i] = _params(v, kind, integer)
    order = sorted(ps, key=lambda i: (-(ps[i][0] * ps[i][2] / ps[i][1]), i))
    total = Fraction(total) if integer else Decimal(total)

    chosen = []
    s1 = s2 = zero  # in:  sum x/g, sum k/g      out: sum y, sum c
    for i in order:
        gam, x, y, k = ps[i]
        if kind == "in":
            t1, t2 = s1 + x / gam, s2 + k / gam
            share = (k * ((total + t1) / t2) - x) / gam
        else:
            t1, t2 = s1 + y, s2 + k
            share = y - k * ((t1 - total) / t2)
        if share <= 0:
            break
        chosen.append(i)
        s1, s2 = t1, t2
    if not chosen:
        if total != 0:
            raise InfeasibleError("no usable venue")
        return out
    if kind == "in":
        level = (total + s1) / s2
        for i in chosen:
            gam, x, y, k = ps[i]
            out[i] = (k * level - x) / gam
    else:
        if s1 - total <= 0:
            raise InfeasibleError("exact output exceeds the reserves of the active venues")
        w = (s1 - total) / s2
        for i in chosen:
            gam, x, y, k = ps[i]
            out[i] = y - k * w
    return out


# --------------------------------------------------------------------------- caps


def _capped(vs, total, kind, integer):
    n = len(vs)
    zero = Fraction(0) if integer else Decimal(0)
    cap_of = lambda i: None if vs[i].cap is None else (Fraction(vs[i].cap) if integer else Decimal(vs[i].cap))
    alloc = [zero] * n
    pinned = set()
    remaining = Fraction(total) if integer else Decimal(total)
    for _ in range(n + 1):
        free = [i for i in range(n) if i not in pinned]
        if not free:
            break
        if remaining < 0:
            raise InfeasibleError("caps exceed the amount")
        part = _uncapped([vs[i] for i in free], remaining, kind, integer)
        over = [j for j, i in enumerate(free) if cap_of(i) is not None and part[j] > cap_of(i)]
        if not over:
            for j, i in enumerate(free):
                alloc[i] = part[j]
            return alloc
        for j in over:
            i = free[j]
            alloc[i] = cap_of(i)
            pinned.add(i)
            remaining -= cap_of(i)
    raise InfeasibleError("the venues' caps cannot fill the amount")


def solve_exact_in_real(vs: List[Venue], amount) -> List[Decimal]:
    """Best split of ``amount`` input. Venue ``cap`` is in input units."""
    return _capped(vs, amount, "in", False)


def solve_exact_out_real(vs: List[Venue], amount) -> List[Decimal]:
    """Cheapest split for ``amount`` output. Venue ``cap`` is in output units."""
    return _capped(vs, amount, "out", False)


def _floor_makers(vs, alloc, total):
    out = [0] * len(vs)
    for i in range(1, len(vs)):
        out[i] = alloc[i].numerator // alloc[i].denominator  # floor
    out[0] = int(total) - sum(out[1:])
    return out


def solve_exact_in_int(vs: List[Venue], amount: int) -> List[int]:
    """Integer allocations that sum to ``amount``; index 0 (the pool) takes the remainder."""
    return _floor_makers(vs, _capped(vs, amount, "in", True), amount)


def solve_exact_out_int(vs: List[Venue], amount: int) -> List[int]:
    return _floor_makers(vs, _capped(vs, amount, "out", True), amount)


# --------------------------------------------------------------------------- the pool as a walk of ranges


class PoolAlloc(NamedTuple):
    pool_by_segment: list  # Decimal, one per segment up to the one the swap ends in
    makers: list  # Decimal, in the order given
    crossed: int  # tick ranges fully used before the last one
    total_out: Decimal  # exact input: total output
    total_in: Decimal  # exact output: total input


def solve_pool_exact_in(segs, makers, amount):
    """Pool + makers, exact input. Solve with the pool as its current range; if its share fills the range,
    fix that range's amounts and solve again from the next one (at most len(segs) passes)."""
    amount = Decimal(amount)
    prefix_in = prefix_out = Decimal(0)
    done = []
    for k, s in enumerate(segs):
        seg_v = Venue(s.x, s.y, s.fee_e9, s.cap_in)
        alloc = solve_exact_in_real([seg_v] + list(makers), amount - prefix_in)
        if k == len(segs) - 1 or s.cap_in is None or alloc[0] < Decimal(s.cap_in):
            out = prefix_out + vn.cp_out_real(seg_v, alloc[0])
            out += sum((vn.cp_out_real(m, a) for m, a in zip(makers, alloc[1:])), Decimal(0))
            return PoolAlloc(done + [alloc[0]], alloc[1:], k, out, Decimal(0))
        done.append(Decimal(s.cap_in))
        prefix_in += Decimal(s.cap_in)
        prefix_out += vn.cp_out_real(seg_v, Decimal(s.cap_in))
    raise InfeasibleError("the pool has no liquidity")


def solve_pool_exact_out(segs, makers, amount):
    amount = Decimal(amount)
    prefix_out = prefix_in = Decimal(0)
    done = []
    for k, s in enumerate(segs):
        seg_v = Venue(s.x, s.y, s.fee_e9, s.cap_out)
        alloc = solve_exact_out_real([seg_v] + list(makers), amount - prefix_out)
        if k == len(segs) - 1 or s.cap_out is None or alloc[0] < Decimal(s.cap_out):
            cost = prefix_in + vn.cp_in_real(seg_v, alloc[0])
            cost += sum((vn.cp_in_real(m, b) for m, b in zip(makers, alloc[1:])), Decimal(0))
            return PoolAlloc(done + [alloc[0]], alloc[1:], k, Decimal(0), cost)
        done.append(Decimal(s.cap_out))
        prefix_out += Decimal(s.cap_out)
        prefix_in += vn.cp_in_real(seg_v, Decimal(s.cap_out))
    raise InfeasibleError("the pool has no liquidity")
