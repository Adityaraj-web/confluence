"""Grid-search optimiser: the referee for waterfill.py (V2-00).

It uses plain floats and shares no formula with the closed form. It only asks each venue model "how much do I
get for this input" (``out``) or "what does this output cost" (``cost``), then searches the allocations:
2 venues on a 1-D grid, 3 venues on a 2-D grid. Each round zooms into the neighbourhood of the best grid point.
"""

import math

import venues as vn

INF = math.inf


class CPModel:
    """A constant-product venue in floats. ``cap`` is input units (exact in) or output units (exact out)."""

    def __init__(self, v, exact_out=False):
        self.x, self.y = float(v.x), float(v.y)
        self.g = 1.0 - v.fee_e9 / 1e9
        cap = INF if v.cap is None else float(v.cap)
        self.max_in = INF if exact_out else cap
        self.max_out = min(cap, self.y * (1 - 1e-12)) if exact_out else self.y

    def out(self, a):
        return self.y * self.g * a / (self.x + self.g * a)

    def cost(self, b):
        if b >= self.y:
            return INF
        return self.x * b / (self.g * (self.y - b))


class PoolModel:
    """The pool as a walk through consecutive tick ranges (Segments), in floats."""

    def __init__(self, segs, exact_out=False):
        self.segs = [
            (
                float(s.x),
                float(s.y),
                1.0 - s.fee_e9 / 1e9,
                INF if s.cap_in is None else float(s.cap_in),
                INF if s.cap_out is None else float(s.cap_out),
            )
            for s in segs
        ]
        self.max_in = sum(s[3] for s in self.segs)
        self.max_out = sum(s[4] for s in self.segs) * (1 - 1e-12) if exact_out else sum(s[4] for s in self.segs)
        if exact_out:
            self.max_in = INF

    def out(self, a):
        total, left = 0.0, a
        for x, y, g, cap_in, _ in self.segs:
            use = min(left, cap_in)
            total += y * g * use / (x + g * use)
            left -= use
            if left <= 0:
                break
        return total

    def cost(self, b):
        total, left = 0.0, b
        for x, y, g, _, cap_out in self.segs:
            use = min(left, cap_out)
            if use >= y:
                return INF
            total += x * use / (g * (y - use))
            left -= use
            if left <= 0:
                break
        return total if left <= 0 else INF


def cp_models(vs, exact_out=False):
    return [CPModel(v, exact_out) for v in vs]


# --------------------------------------------------------------------------- search


def _search(f, bounds, steps, rounds, maximise):
    """Optimise f over a box by repeated grids. ``f`` returns None where infeasible."""
    best_pt, best_val = None, None
    outer = list(bounds)
    boxes = list(bounds)
    for _ in range(rounds):
        grids = []
        for lo, hi in boxes:
            n = steps
            grids.append([lo + (hi - lo) * i / n for i in range(n + 1)] if hi > lo else [lo])
        best_pt, best_val = None, None
        for pt in _product(grids):
            val = f(pt)
            if val is None:
                continue
            if best_val is None or (val > best_val if maximise else val < best_val):
                best_pt, best_val = pt, val
        if best_pt is None:
            raise ValueError("no feasible allocation")
        boxes = []
        for (lo, hi), g, p in zip(outer, grids, best_pt):
            step = (g[-1] - g[0]) / max(len(g) - 1, 1)
            boxes.append((max(lo, p - 2 * step), min(hi, p + 2 * step)))
    return best_pt, best_val


def _product(grids):
    if len(grids) == 1:
        for a in grids[0]:
            yield (a,)
    else:
        for a in grids[0]:
            for rest in _product(grids[1:]):
                yield (a,) + rest


def exact_in(models, amount, steps2=2000, steps3=240, rounds=6):
    """Max total output for ``amount`` input over 2 or 3 venues. Returns (best, allocation)."""
    A = float(amount)
    n = len(models)
    if n not in (2, 3):
        raise ValueError("2 or 3 venues")
    last = models[-1]

    def feasible(pt):
        rest = A - sum(pt)
        if rest < -1e-9 * A or rest > last.max_in * (1 + 1e-12):
            return None
        return max(rest, 0.0)

    def f(pt):
        rest = feasible(pt)
        if rest is None:
            return None
        return sum(m.out(a) for m, a in zip(models, pt)) + last.out(rest)

    bounds = [(0.0, min(A, m.max_in)) for m in models[:-1]]
    pt, val = _search(f, bounds, steps2 if n == 2 else steps3, rounds, True)
    return val, list(pt) + [A - sum(pt)]


def exact_out(models, amount, steps2=2000, steps3=240, rounds=6):
    """Min total input for ``amount`` output over 2 or 3 venues. Returns (best, allocation)."""
    B = float(amount)
    n = len(models)
    if n not in (2, 3):
        raise ValueError("2 or 3 venues")
    last = models[-1]

    def f(pt):
        rest = B - sum(pt)
        if rest < -1e-9 * B or rest > last.max_out * (1 + 1e-12):
            return None
        rest = max(rest, 0.0)
        val = sum(m.cost(b) for m, b in zip(models, pt)) + last.cost(rest)
        return None if val == INF else val

    bounds = [(0.0, min(B, m.max_out)) for m in models[:-1]]
    pt, val = _search(f, bounds, steps2 if n == 2 else steps3, rounds, False)
    return val, list(pt) + [B - sum(pt)]
