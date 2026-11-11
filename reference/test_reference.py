"""V2-00 acceptance tests for the Python reference model.

Run from the repo root:  python3 -m unittest reference/test_reference.py

Standard library only. Cases are seeded, so every run checks the same inputs.
"""

import filecmp
import os
import random
import subprocess
import sys
import tempfile
import unittest
from decimal import Decimal
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import brute  # noqa: E402
import gen_vectors  # noqa: E402
import venues  # noqa: E402
import waterfill  # noqa: E402

VECTORS_DIR = HERE.parent / "contracts" / "test" / "vectors"

# D-21: the v1 pool-only result for 1,000 USDC, in MUMB wei.
V1_POOL_ONLY_WEI = 984934194542570551127
V1_HINT = 550_000_000
V1_HINTED_BEST_WEI = 991549823315669231761
V1_AQUA_LEG_WEI = 545359521066233309646
V1_POOL_LEG_WEI = 446190302249435922115

REL_TOL = Decimal("1e-6")


def rand_venues(rng, n, capped=False):
    """n constant-product venues around a 1:1 price, with different sizes and fees."""
    fees = [500_000, 1_000_000, 3_000_000, 5_000_000, 10_000_000]
    out = []
    for i in range(n):
        x = int((1 + 9 * rng.random()) * 10**21)
        y = int(x * (0.95 + 0.1 * rng.random()))
        out.append(venues.Venue(x, y, fees[int(rng.random() * len(fees))], None))
    return out


def rel_err(a, b):
    return abs(Decimal(a) - Decimal(b)) / max(abs(Decimal(b)), Decimal(1))


class ClosedFormVsBrute(unittest.TestCase):
    """The closed form (waterfill.py) against a grid search that shares none of its code."""

    def _check_in(self, vs, amount):
        alloc = waterfill.solve_exact_in_real(vs, amount)
        self.assertLess(abs(sum(alloc) - Decimal(amount)), Decimal("1e-20") * Decimal(amount), "allocations != A")
        for a, v in zip(alloc, vs):
            self.assertGreaterEqual(a, 0)
            if v.cap is not None:
                self.assertLessEqual(a, Decimal(v.cap) * (1 + Decimal("1e-30")))
        closed = sum(venues.cp_out_real(v, a) for v, a in zip(vs, alloc))
        best, _ = brute.exact_in(brute.cp_models(vs), amount)
        self.assertLess(rel_err(closed, best), REL_TOL, f"closed {closed} brute {best}")
        # The closed form must not be worse than the grid by more than the tolerance.
        self.assertGreaterEqual(closed, Decimal(best) * (1 - REL_TOL))

    def _check_out(self, vs, amount):
        alloc = waterfill.solve_exact_out_real(vs, amount)
        self.assertLess(abs(sum(alloc) - Decimal(amount)), Decimal("1e-20") * Decimal(amount), "allocations != B")
        for b, v in zip(alloc, vs):
            self.assertGreaterEqual(b, 0)
            if v.cap is not None:
                self.assertLessEqual(b, Decimal(v.cap) * (1 + Decimal("1e-30")))
        closed = sum(venues.cp_in_real(v, b) for v, b in zip(vs, alloc))
        best, _ = brute.exact_out(brute.cp_models(vs, exact_out=True), amount)
        self.assertLess(rel_err(closed, best), REL_TOL, f"closed {closed} brute {best}")
        self.assertLessEqual(closed, Decimal(best) * (1 + REL_TOL))

    def test_closed_form_matches_brute(self):
        rng = random.Random(20261111)
        for n in (2, 3):
            for _ in range(5):
                vs = rand_venues(rng, n)
                total_x = sum(v.x for v in vs)
                total_y = sum(v.y for v in vs)
                self._check_in(vs, int(total_x * (0.002 + 0.2 * rng.random())))
                self._check_out(vs, int(total_y * (0.002 + 0.2 * rng.random())))

    def test_closed_form_matches_brute_with_caps(self):
        rng = random.Random(20261112)
        for n in (2, 3):
            for _ in range(4):
                vs = rand_venues(rng, n)
                a = int(sum(v.x for v in vs) * 0.15)
                free = waterfill.solve_exact_in_real(vs, a)
                # Cap the venue that gets the most at 40% of its free share, so the cap binds.
                big = max(range(n), key=lambda i: free[i])
                capped = [v._replace(cap=int(free[i] * Decimal("0.4"))) if i == big else v for i, v in enumerate(vs)]
                self._check_in(capped, a)
                self.assertEqual(waterfill.solve_exact_in_real(capped, a)[big], Decimal(capped[big].cap))

                b = int(sum(v.y for v in vs) * 0.15)
                free_o = waterfill.solve_exact_out_real(vs, b)
                big_o = max(range(n), key=lambda i: free_o[i])
                capped_o = [
                    v._replace(cap=int(free_o[i] * Decimal("0.4"))) if i == big_o else v for i, v in enumerate(vs)
                ]
                self._check_out(capped_o, b)
                self.assertEqual(waterfill.solve_exact_out_real(capped_o, b)[big_o], Decimal(capped_o[big_o].cap))

    def test_integer_mode_sums_exactly(self):
        rng = random.Random(20261113)
        for n in (2, 3):
            vs = rand_venues(rng, n)
            a = 123_456_789_012_345_678_901
            alloc = waterfill.solve_exact_in_int(vs, a)
            self.assertEqual(sum(alloc), a)
            # Maker amounts are floors of the real solution, so they never exceed it by more than 1.
            real = waterfill.solve_exact_in_real(vs, a)
            for i in range(1, n):
                self.assertLessEqual(abs(Decimal(alloc[i]) - real[i]), 1)
            b = 98_765_432_109_876_543_210
            alloc_o = waterfill.solve_exact_out_int(vs, b)
            self.assertEqual(sum(alloc_o), b)


class PoolCrossing(unittest.TestCase):
    """A pool whose tick ranges are crossed, plus one maker, against the grid search."""

    def test_pool_crossing_matches_brute(self):
        state = gen_vectors.crossing_pool()
        maker = gen_vectors.CROSSING_MAKER
        tiny = Decimal("1e-20")
        for zfo in (True, False):
            segs = venues.pool_segments(state, zfo, venues.MAX_TICK_RANGES)
            self.assertGreaterEqual(len(segs), 3, "the test pool should have several ranges")
            for amount in gen_vectors.CROSSING_AMOUNTS_IN:
                alloc = waterfill.solve_pool_exact_in(segs, [maker], amount)
                self.assertLess(abs(sum(alloc.pool_by_segment) + sum(alloc.makers) - Decimal(amount)), tiny * amount)
                self.assertGreaterEqual(alloc.crossed, 1, "the walk should cross at least one tick")
                best, _ = brute.exact_in([brute.PoolModel(segs), brute.cp_models([maker])[0]], amount)
                self.assertLess(rel_err(alloc.total_out, best), REL_TOL, f"zfo={zfo} amount={amount}")

            for amount in gen_vectors.CROSSING_AMOUNTS_OUT:
                alloc = waterfill.solve_pool_exact_out(segs, [maker], amount)
                self.assertLess(abs(sum(alloc.pool_by_segment) + sum(alloc.makers) - Decimal(amount)), tiny * amount)
                self.assertGreaterEqual(alloc.crossed, 1, "the walk should cross at least one tick")
                best, _ = brute.exact_out(
                    [brute.PoolModel(segs, exact_out=True), brute.cp_models([maker], exact_out=True)[0]], amount
                )
                self.assertLess(rel_err(alloc.total_in, best), REL_TOL, f"out zfo={zfo} amount={amount}")


class V1Numbers(unittest.TestCase):
    """The v1 demo pool: the model must reproduce D-21 and the D-27 closed-form claim."""

    def test_pool_only_matches_v1(self):
        usdc_is_c0 = gen_vectors.V1_USDC_IS_CURRENCY0
        state = venues.v1_demo_pool(usdc_is_c0)
        # 1. Integer mode: v4's own rounding, exactly D-21's number.
        res = venues.pool_swap_exact_in(state, 1_000 * 10**6, zero_for_one=usdc_is_c0)
        self.assertEqual(res.amount_in, 1_000 * 10**6)
        self.assertEqual(res.amount_out, V1_POOL_ONLY_WEI)
        # 2. Real-valued (Decimal) mode: 984.934195 MUMB to 6 decimal places.
        seg = venues.pool_segments(state, usdc_is_c0, 1)[0]
        out = venues.cp_out_real(venues.Venue(seg.x, seg.y, seg.fee_e9, None), Decimal(1_000 * 10**6))
        self.assertEqual((out / Decimal(10**18)).quantize(Decimal("0.000001")), Decimal("984.934195"))

    def test_pool_only_2000_matches_d23(self):
        """A second, independent number from the v1 record: D-23's 2,000 USDC pool-only demo result."""
        usdc_is_c0 = gen_vectors.V1_USDC_IS_CURRENCY0
        res = venues.pool_swap_exact_in(venues.v1_demo_pool(usdc_is_c0), 2_000 * 10**6, zero_for_one=usdc_is_c0)
        self.assertEqual(res.amount_out, 1946313880914421030318)

    def test_v1_hinted_legs_match_d21(self):
        usdc_is_c0 = gen_vectors.V1_USDC_IS_CURRENCY0
        state = venues.v1_demo_pool(usdc_is_c0)
        priya = venues.Venue(100_000 * 10**6, 100_000 * 10**18, 3_000_000, None)
        aqua_out = venues.cp_out_int(priya, V1_HINT)
        pool = venues.pool_swap_exact_in(state, 1_000 * 10**6 - V1_HINT, zero_for_one=usdc_is_c0)
        self.assertEqual(aqua_out, V1_AQUA_LEG_WEI)
        self.assertEqual(pool.amount_out, V1_POOL_LEG_WEI)
        self.assertEqual(aqua_out + pool.amount_out, V1_HINTED_BEST_WEI)

    def test_v1_closed_form_beats_hinted_best(self):
        usdc_is_c0 = gen_vectors.V1_USDC_IS_CURRENCY0
        state = venues.v1_demo_pool(usdc_is_c0)
        seg = venues.pool_segments(state, usdc_is_c0, 1)[0]
        pool_v = venues.Venue(seg.x, seg.y, seg.fee_e9, None)
        priya = venues.Venue(100_000 * 10**6, 100_000 * 10**18, 3_000_000, None)
        alloc = waterfill.solve_exact_in_real([pool_v, priya], 1_000 * 10**6)
        share = alloc[1] / Decimal(1_000 * 10**6)
        total = venues.cp_out_real(pool_v, alloc[0]) + venues.cp_out_real(priya, alloc[1])
        # D-27 / ARCHITECTURE-v2 section 3: 55.13% to Aqua, 991.549861 MUMB.
        self.assertEqual(share.quantize(Decimal("0.0001")), Decimal("0.5513"))
        self.assertEqual((total / Decimal(10**18)).quantize(Decimal("0.000001")), Decimal("991.549861"))
        self.assertGreater(total, Decimal(V1_HINTED_BEST_WEI))


class TickMath(unittest.TestCase):
    def test_known_values(self):
        self.assertEqual(venues.sqrt_price_at_tick(0), 1 << 96)
        self.assertEqual(venues.sqrt_price_at_tick(venues.MIN_TICK), venues.MIN_SQRT_PRICE)
        self.assertEqual(venues.sqrt_price_at_tick(venues.MAX_TICK), venues.MAX_SQRT_PRICE)
        for t in (-276325, -60, 1, 60, 276324):
            self.assertEqual(venues.tick_at_sqrt_price(venues.sqrt_price_at_tick(t)), t)


class Vectors(unittest.TestCase):
    def test_vectors_deterministic(self):
        first = gen_vectors.generate()
        second = gen_vectors.generate()
        self.assertEqual(first, second, "two in-process runs differ")
        self.assertTrue(first, "no vector files generated")

        # Two separate processes write byte-identical files, and they equal the committed ones.
        with tempfile.TemporaryDirectory() as d1, tempfile.TemporaryDirectory() as d2:
            for d in (d1, d2):
                subprocess.run(
                    [sys.executable, "-I", str(HERE / "gen_vectors.py"), "--out", d],
                    check=True,
                    capture_output=True,
                    env={k: v for k, v in os.environ.items() if k != "PYTHONHASHSEED"},
                )
            self.assertEqual(sorted(os.listdir(d1)), sorted(os.listdir(d2)))
            self.assertEqual(sorted(os.listdir(d1)), sorted(first))
            for name in first:
                self.assertTrue(filecmp.cmp(os.path.join(d1, name), os.path.join(d2, name), shallow=False), name)
                self.assertEqual((Path(d1) / name).read_text(), first[name], name)

        self.assertTrue(VECTORS_DIR.is_dir(), f"{VECTORS_DIR} is missing: run reference/gen_vectors.py")
        self.assertEqual(sorted(os.listdir(VECTORS_DIR)), sorted(first), "committed vector files differ from generated")
        for name, text in first.items():
            self.assertEqual((VECTORS_DIR / name).read_text(), text, f"{name} is stale: rerun gen_vectors.py")


if __name__ == "__main__":
    unittest.main()
