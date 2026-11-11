# Reference model (V2-00)

One source of truth for the right answer, outside Solidity. Python standard library only.

| File | Job |
| --- | --- |
| `venues.py` | Constant-product venues; exact ports of Uniswap v4 `TickMath`, `SqrtPriceMath`, `SwapMath` and `Pool.swap`; the v1 demo pool |
| `waterfill.py` | The closed-form split (ARCHITECTURE-v2 section 3): exact in and exact out, active set, caps, piecewise pool walk |
| `brute.py` | Float grid search over 2 and 3 venues; the referee for `waterfill.py`. Shares no formula with it |
| `gen_vectors.py` | Writes the JSON vectors in `contracts/test/vectors/` |
| `test_reference.py` | The acceptance tests |

## Run (from the repo root)

```
python3 -m unittest reference/test_reference.py     # about 7 s
python3 reference/gen_vectors.py                    # rewrites contracts/test/vectors; rerun gives identical bytes
```

## Two arithmetics

* **Real** (`*_real`): `decimal.Decimal`, 60 digits. Used to check the closed form against the grid search
  (relative error < 1e-6 on the total output for exact input, the total input for exact output).
* **Integer** (`*_int`, and the v4 ports): mirrors the contracts. Maker amounts are floors, the pool (index 0)
  takes the remainder so the parts sum exactly. SwapVM makers: flat fee rounded up on the input, then XYC
  rounded down. The pool uses v4's own rounding, so pool-only results match the chain to the wei.

## Vectors

Every file is `{schema: "confluence-vectors/1", file, description, count, cases[]}`. Integers above 2^53 are
decimal strings. A venue is `{x, y, feeE9, cap}` (`cap` is `2^256 - 1` when there is none); index 0 is the pool.

| File | Case fields |
| --- | --- |
| `split_2v`, `split_3v`, `split_caps` | `mode` (`in`/`out`), `amount`, `venues[]`, `alloc[]`, `perVenue[]` (output for `in`, input for `out`), `totalInt`, `totalReal` (6 dp) |
| `pool_crossing` | `mode`, `amount`, `pool` (state and ticks), `segments[]` (the pool's ranges as venues: `x, y, feeE9, capIn, capOut, liquidity`), `maker`, `allocPool`, `allocMaker`, `poolLeg`, `makerLeg`, `rangesCrossed`, `ticksCrossed`, `totalInt`, `totalReal` |
| `v1_demo` | `pool`, `poolVenue`, `priya`, `poolOnlyOut`, `closedForm{allocPool, allocPriya, poolLeg, priyaLeg, totalInt, totalReal}`, and `v1Hinted` on the 1,000 USDC case |

The v1 test pool has USDC as currency0 (`V1_USDC_IS_CURRENCY0`). With the other order the model gives
984709647489642186967 for the 1,000 USDC trade, not D-21's number.
