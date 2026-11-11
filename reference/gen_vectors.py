"""Writes the JSON test vectors the Solidity tests read (V2-00).

    python3 reference/gen_vectors.py [--out DIR]       default DIR: contracts/test/vectors

Output is deterministic: seeded generators, sorted keys, fixed indent, no timestamps. Running it twice gives the
same bytes. Integers that may exceed 2**53 are decimal strings. A venue is
{x, y, feeE9, cap}; ``cap`` is the maximum uint256 when there is none. Index 0 of every venue list is the pool:
it is never capped and takes the remainder, so the parts sum exactly.

Files
  split_2v.json, split_3v.json   plain venues, exact input and exact output (V2-01)
  split_caps.json                one venue pinned at its cap (V2-01)
  pool_crossing.json             pool whose tick ranges are crossed, plus one maker (V2-02)
  v1_demo.json                   the v1 demo pool and Priya, the numbers V2-07 must beat
"""

import argparse
import json
import random
import sys
from decimal import Decimal
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import venues as vn  # noqa: E402
import waterfill as wf  # noqa: E402
from venues import MAX_UINT256, Venue  # noqa: E402

SCHEMA = "confluence-vectors/1"
DEFAULT_OUT = HERE.parent / "contracts" / "test" / "vectors"

# Currency order of the v1 test pool. With USDC as currency0 the model reproduces D-21 to the wei (the other
# order gives 984709647489642186967); V200ForkOracle asserts the fork has the same order.
V1_USDC_IS_CURRENCY0 = True

FEES_E9 = [500_000, 1_000_000, 3_000_000, 5_000_000, 10_000_000]  # 0.05% .. 1%

# The pool used by the crossing vectors: price 1:1 (tick 0), nested positions so a swap walks several ranges.
CROSSING_TICKS = ((-180, 10**22), (-120, 2 * 10**22), (-60, 3 * 10**22), (60, -3 * 10**22), (120, -2 * 10**22), (180, -(10**22)))
CROSSING_MAKER = Venue(2 * 10**22, 2 * 10**22, 3_000_000, None)
# 3e20 crosses one range, 4e20 two (measured); the pool's whole capacity is about 3.02e20 input.
CROSSING_AMOUNTS_IN = (3 * 10**20, 4 * 10**20)
CROSSING_AMOUNTS_OUT = (3 * 10**20, 4 * 10**20)


def crossing_pool():
    liq = sum(net for t, net in CROSSING_TICKS if t < 0)
    return vn.PoolState(vn.Q96, liq, 0, 3000, CROSSING_TICKS, 60)


# --------------------------------------------------------------------------- serialisation


def s(n):
    return str(int(n))


def venue_json(v):
    return {"x": s(v.x), "y": s(v.y), "feeE9": v.fee_e9, "cap": s(MAX_UINT256 if v.cap is None else v.cap)}


def real_str(d):
    return format(Decimal(d).quantize(Decimal("0.000001")), "f")


def dump(name, description, cases):
    doc = {"schema": SCHEMA, "file": name, "description": description, "count": len(cases), "cases": cases}
    return json.dumps(doc, indent=2, sort_keys=True) + "\n"


# --------------------------------------------------------------------------- plain split cases


def split_case(name, mode, vs, amount):
    """One case: the integer-mode allocation and the totals it gives, plus the real-valued total."""
    if mode == "in":
        alloc = wf.solve_exact_in_int(vs, amount)
        per = [vn.cp_out_int(v, a) for v, a in zip(vs, alloc)]
        real = wf.solve_exact_in_real(vs, amount)
        total_real = sum(vn.cp_out_real(v, a) for v, a in zip(vs, real))
    else:
        alloc = wf.solve_exact_out_int(vs, amount)
        per = [vn.cp_in_int(v, b) if b > 0 else 0 for v, b in zip(vs, alloc)]
        real = wf.solve_exact_out_real(vs, amount)
        total_real = sum(vn.cp_in_real(v, b) for v, b in zip(vs, real))
    for v, a in zip(vs, alloc):
        assert a >= 0 and (v.cap is None or a <= v.cap), (name, a, v)
    assert sum(alloc) == amount
    return {
        "name": name,
        "mode": mode,
        "amount": s(amount),
        "venues": [venue_json(v) for v in vs],
        "alloc": [s(a) for a in alloc],
        "perVenue": [s(p) for p in per],
        "totalInt": s(sum(per)),
        "totalReal": real_str(total_real),
    }


def random_venues(rng, n):
    out = []
    for _ in range(n):
        x = int((1 + 9 * rng.random()) * 10**21)
        y = int(x * (0.95 + 0.1 * rng.random()))
        out.append(Venue(x, y, FEES_E9[int(rng.random() * len(FEES_E9))], None))
    return out


def split_file(n, seed):
    rng = random.Random(seed)
    cases = []
    for k in range(6):
        vs = random_venues(rng, n)
        a = int(sum(v.x for v in vs) * (0.002 + 0.2 * rng.random()))
        b = int(sum(v.y for v in vs) * (0.002 + 0.2 * rng.random()))
        cases.append(split_case(f"{n}v-in-{k}", "in", vs, a))
        cases.append(split_case(f"{n}v-out-{k}", "out", vs, b))
    # A venue that is too expensive to be used at this size: it must get exactly zero.
    vs = random_venues(rng, n)
    vs[-1] = Venue(vs[-1].x, int(vs[-1].y * 0.9), vs[-1].fee_e9, None)
    cases.append(split_case(f"{n}v-in-unused-venue", "in", vs, int(vs[0].x * 0.0005)))
    cases.append(split_case(f"{n}v-out-unused-venue", "out", vs, int(vs[0].y * 0.0005)))
    return dump(f"split_{n}v", f"{n} constant-product venues, no caps. Index 0 is the pool.", cases)


def caps_file(seed):
    rng = random.Random(seed)
    cases = []
    for n in (2, 3):
        for k in range(3):
            vs = random_venues(rng, n)
            a = int(sum(v.x for v in vs) * 0.15)
            b = int(sum(v.y for v in vs) * 0.15)
            for mode, amount in (("in", a), ("out", b)):
                free = (wf.solve_exact_in_real if mode == "in" else wf.solve_exact_out_real)(vs, amount)
                big = max(range(1, n), key=lambda i: free[i])  # never the pool
                for tag, factor in (("binding", Decimal("0.4")), ("slack", Decimal(3))):
                    capped = [v._replace(cap=int(free[i] * factor)) if i == big else v for i, v in enumerate(vs)]
                    cases.append(split_case(f"{n}v-{mode}-cap-{tag}-{k}", mode, capped, amount))
    return dump("split_caps", "Venues with a cap on one maker (binding or slack). Index 0 is the pool.", cases)


# --------------------------------------------------------------------------- pool crossing


def segment_json(sg):
    return {
        "x": s(sg.x),
        "y": s(sg.y),
        "feeE9": sg.fee_e9,
        "capIn": s(MAX_UINT256 if sg.cap_in is None else sg.cap_in),
        "capOut": s(MAX_UINT256 if sg.cap_out is None else sg.cap_out),
        "liquidity": s(sg.liquidity),
    }


def pool_json(state, zero_for_one):
    return {
        "sqrtPriceX96": s(state.sqrt_price),
        "liquidity": s(state.liquidity),
        "tick": state.tick,
        "feePips": state.fee_pips,
        "tickSpacing": state.tick_spacing,
        "zeroForOne": zero_for_one,
        "ticks": [{"tick": t, "liquidityNet": s(n)} for t, n in state.ticks],
    }


def crossing_case(name, mode, state, zero_for_one, maker, amount):
    segs_real = vn.pool_segments(state, zero_for_one, vn.MAX_TICK_RANGES)
    segs_int = vn.pool_segments(state, zero_for_one, vn.MAX_TICK_RANGES, integer=True)
    if mode == "in":
        alloc = wf.solve_pool_exact_in(segs_real, [maker], amount)
        maker_alloc = int(alloc.makers[0])  # floor
        pool_alloc = amount - maker_alloc
        pool = vn.pool_swap_exact_in(state, pool_alloc, zero_for_one)
        maker_leg = vn.cp_out_int(maker, maker_alloc) if maker_alloc > 0 else 0
        pool_leg, pool_other = pool.amount_out, pool.amount_in
        total_int, total_real = pool_leg + maker_leg, alloc.total_out
        assert pool_other == pool_alloc, "the pool could not take its whole share"
    else:
        alloc = wf.solve_pool_exact_out(segs_real, [maker], amount)
        maker_alloc = int(alloc.makers[0])
        pool_alloc = amount - maker_alloc
        pool = vn.pool_swap_exact_out(state, pool_alloc, zero_for_one)
        maker_leg = vn.cp_in_int(maker, maker_alloc) if maker_alloc > 0 else 0
        pool_leg, pool_other = pool.amount_in, pool.amount_out
        total_int, total_real = pool_leg + maker_leg, alloc.total_in
        assert pool_other == pool_alloc, "the pool could not give its whole share"
    return {
        "name": name,
        "mode": mode,
        "amount": s(amount),
        "pool": pool_json(state, zero_for_one),
        "segments": [segment_json(sg) for sg in segs_int],
        "maker": venue_json(maker),
        "allocPool": s(pool_alloc),
        "allocMaker": s(maker_alloc),
        "poolLeg": s(pool_leg),
        "makerLeg": s(maker_leg),
        "rangesCrossed": alloc.crossed,
        "ticksCrossed": pool.crossed,
        "totalInt": s(total_int),
        "totalReal": real_str(total_real),
    }


def crossing_file():
    state = crossing_pool()
    cases = []
    for zfo in (True, False):
        d = "zfo" if zfo else "ofz"
        for k, amount in enumerate(CROSSING_AMOUNTS_IN):
            cases.append(crossing_case(f"cross-{d}-in-{k}", "in", state, zfo, CROSSING_MAKER, amount))
        for k, amount in enumerate(CROSSING_AMOUNTS_OUT):
            cases.append(crossing_case(f"cross-{d}-out-{k}", "out", state, zfo, CROSSING_MAKER, amount))
    for c in cases:
        assert c["rangesCrossed"] >= 1, c["name"]
    return dump("pool_crossing", "A pool whose tick ranges are crossed, plus one maker. Index 0 is the pool.", cases)


# --------------------------------------------------------------------------- the v1 demo


def v1_demo_file():
    c0 = V1_USDC_IS_CURRENCY0
    cases = []
    priya_usdc_in = Venue(100_000 * 10**6, 100_000 * 10**18, 3_000_000, None)
    priya_mumb_in = Venue(100_000 * 10**18, 100_000 * 10**6, 3_000_000, None)
    for name, amount, zfo, priya in (
        ("usdc-to-mumb-1000", 1_000 * 10**6, c0, priya_usdc_in),
        ("usdc-to-mumb-2000", 2_000 * 10**6, c0, priya_usdc_in),
        ("mumb-to-usdc-1000", 1_000 * 10**18, not c0, priya_mumb_in),
        # Crosses a 256-tick word edge of v4's tick bitmap (tick 276420): the swap takes two steps, each rounded.
        ("mumb-to-usdc-777", 777 * 10**18, not c0, priya_mumb_in),
    ):
        state = vn.v1_demo_pool(c0)
        seg_int = vn.pool_segments(state, zfo, vn.MAX_TICK_RANGES, integer=True)[0]
        seg_real = vn.pool_segments(state, zfo, vn.MAX_TICK_RANGES)[0]
        pool_real = Venue(seg_real.x, seg_real.y, seg_real.fee_e9, None)
        pool_only = vn.pool_swap_exact_in(state, amount, zfo)
        real = wf.solve_exact_in_real([pool_real, priya], amount)
        priya_alloc = int(real[1])  # floor; the pool takes the rest
        pool_alloc = amount - priya_alloc
        pool_leg = vn.pool_swap_exact_in(state, pool_alloc, zfo).amount_out
        priya_leg = vn.cp_out_int(priya, priya_alloc)
        total_real = vn.cp_out_real(pool_real, real[0]) + vn.cp_out_real(priya, real[1])
        cases.append(
            {
                "name": name,
                "amount": s(amount),
                "pool": pool_json(state, zfo),
                "poolVenue": {"x": s(seg_int.x), "y": s(seg_int.y), "feeE9": seg_int.fee_e9, "capIn": s(seg_int.cap_in)},
                "priya": venue_json(priya),
                "poolOnlyOut": s(pool_only.amount_out),
                "poolOnlySteps": pool_only.steps,
                "closedForm": {
                    "allocPool": s(pool_alloc),
                    "allocPriya": s(priya_alloc),
                    "poolLeg": s(pool_leg),
                    "priyaLeg": s(priya_leg),
                    "totalInt": s(pool_leg + priya_leg),
                    "totalReal": real_str(total_real),
                },
            }
        )
    # v1's hinted best (D-21): the target the hint-free split must reach or beat (gate M3).
    state = vn.v1_demo_pool(c0)
    hint = 550_000_000
    aqua_leg = vn.cp_out_int(priya_usdc_in, hint)
    pool_leg = vn.pool_swap_exact_in(state, 1_000 * 10**6 - hint, c0).amount_out
    cases[0]["v1Hinted"] = {"hint": s(hint), "aquaLeg": s(aqua_leg), "poolLeg": s(pool_leg), "total": s(aqua_leg + pool_leg)}
    return dump("v1_demo", "The v1 demo pool (F04) and Priya's strategy (F05). USDC is currency0.", cases)


# --------------------------------------------------------------------------- entry points


def generate():
    """{file name: text}. Pure: no I/O."""
    return {
        "split_2v.json": split_file(2, 20261101),
        "split_3v.json": split_file(3, 20261102),
        "split_caps.json": caps_file(20261103),
        "pool_crossing.json": crossing_file(),
        "v1_demo.json": v1_demo_file(),
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", default=str(DEFAULT_OUT), help="directory to write the JSON files to")
    args = ap.parse_args(argv)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    files = generate()
    for name, text in files.items():
        (out / name).write_text(text)
    print(f"wrote {len(files)} files to {out}")


if __name__ == "__main__":
    main()
