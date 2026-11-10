# CONFLUENCE v2 architecture (Phase 1)

v2 turns the hook into a small on-chain router. Inside `beforeSwap` it reads every venue's state, solves for the best split in closed form, fills the maker legs through 1inch's deployed router, and lets the pool fill the rest. A swap needs nothing off-chain: `hookData` is ignored.

v1 (`docs/ARCHITECTURE.md`, tag `v1-hackathon`, frozen in `contracts/src/v1/` by V2-00) stays the reference for everything this file does not change. V2-12 merges the two files.

## 1. Contracts

| Contract | Kind | Job | Spec |
| --- | --- | --- | --- |
| `ConfluenceHook` | v4 hook, immutable, no owner, written fresh (v1 lives in `src/v1/`) | `beforeSwap`: update the anchor, build venues, solve, run maker legs, return the delta. Stores the anchor and the maker registry | V2-03, V2-05, V2-07, V2-08 |
| `SplitMath` | Library, pure | Water-filling across N venues, exact input and exact output, a cap per venue | V2-01 |
| `PoolVenue` | Library, view | Reads `slot0`, liquidity, fees and initialized ticks; returns up to 8 tick-range segments | V2-02 |
| `MakerVenue` | Library, view | Reads Aqua virtual balances, the maker's wallet balance and allowance; returns reserves and caps | V2-06 |
| `AnchorLib` | Library | Block-start snapshot and EMA update | V2-03 |
| `StrategyTemplate` | Library, pure | Builds and checks template T1's program bytes: fee, XYC curve, BandGuardV2 | V2-05 |
| `BandGuardV2` | Extruction target, stateless | Runs inside the maker's program; checks the fill against the hook's anchor; optional only-the-hook taker rule | V2-04 |
| `ConfluenceLens` | View contract | The hook's maths as a full breakdown, for apps, solvers and indexers | V2-09 |
| PoolManager, AquaSwapVMRouter v1.0.2, Aqua | Canonical | Used as deployed | — |

Libraries are `internal` unless the hook nears the 24 KB limit; V2-07 measures and decides (DECISIONS entry).

Taker access: 1inch's own dApp adds `_onlyTxOriginTokenBalanceNonZero(KycNFT)` to every position, so only KYB-verified resolvers fill those. CONFLUENCE strategies are built by `StrategyTemplate` without that opcode, as in v1, and BandGuardV2 can restrict the taker to the hook instead. v1 proved an ungated program fills through mainnet's router at FORK_BLOCK 26349400. 1inch's docs describe the deployed router as default-deny, so V2-05's first test re-checks this on the target chain [VERIFY].

## 2. One swap, step by step

1. Any caller swaps on the pool with empty `hookData`: a router, the V4Quoter, a wallet, a contract.
2. `beforeSwap`, first swap of the block only: record the block-start snapshot from `slot0` and move the EMA toward it (section 4).
3. Build venues. The pool gives up to 8 tick-range segments in the swap's direction, ending at the trader's `sqrtPriceLimitX96`. Each registered maker gives virtual reserves, its fee factor and a cap = min(band cap, wallet balance, allowance to Aqua, PoolManager balance of the input token). Makers whose curve price is outside their band of the snapshot, or whose drift limit is broken, are dropped.
4. Solve with `SplitMath`. Drop legs under `MIN_LEG_BPS` of the trade; keep at most `MAX_LEGS` maker legs (the largest).
5. For each maker leg: `take` the input from the PoolManager, approve the router for exactly that amount, call `swap` inside try/catch with a gas cap. BandGuardV2 runs inside the program; Aqua pulls output from the maker's wallet to the hook. A failed leg: settle its input back, reset the approval, record the reason.
6. Settle the total output into the PoolManager and return the delta. Exact input: specified `+Σa`, unspecified `−Σb`. Exact output: specified `−Σb`, unspecified `+Σa`. Signs confirmed red-first (v1 D-14 style). Emit one `ConfluenceSwap` event.
7. The pool's curve fills the remainder, including any failed leg's share. The PoolManager checks every balance nets to zero.

## 3. Split maths

Every venue is a constant-product curve: an Aqua XYC strategy as is, a v4 pool one tick range at a time. Reserves X (input token) and Y (output token), fee factor γ = 1 − fee:

```
out(a) = Y·γ·a / (X + γ·a)
```

Exact input, trade size A, active set S:

```
k_i  = sqrt(γ_i · X_i · Y_i)
1/s  = (A + Σ_{j∈S} X_j/γ_j) / (Σ_{j∈S} k_j/γ_j)
a_i  = (k_i/s − X_i) / γ_i
```

Active set: sort by starting rate γY/X, add venues while their share stays positive. A venue over its cap is pinned at the cap and the rest re-solved; at most N passes.

Exact output, required output B (least total input):

```
c_i = sqrt(X_i · Y_i / γ_i)
w   = (Σ_{j∈S} Y_j − B) / Σ_{j∈S} c_j
b_i = Y_i − c_i · w
```

Pool: liquidity changes at initialized ticks but the marginal rate (γ × price) is continuous, so solve assuming the pool ends inside its current range; if its share would cross the boundary, fix the crossed segment's amounts and re-solve from the next range. Walk at most 8 ranges; past that the pool takes the rest (valid, slightly less optimal).

Checked (Python, against a 2,000-step brute force) on the v1 demo setup: pool seed 2,500/2,500 over ±600 ticks (virtual 81,385.3 each side), maker 100,000/100,000, both fees 0.30%. Pool-only 1,000 USDC = 984.934195 MUMB (equals v1's measured 984.934194542570551127). Closed form: 55.13% to Aqua, 991.549861 MUMB (v1's hinted best: 991.549823315669231761). Exact-output with three venues and a cap matched brute force to 1e-6.

## 4. Anchor

Every price change on a v4 pool is a swap, and every swap calls `beforeSwap` first, so the block-start price is `slot0` at the block's first `beforeSwap`. The hook records it before anything in the block can move it.

```
snap      = slot0 tick at the first beforeSwap of the block
ema_new   = snap + (ema_old − snap) · 2^(−Δt / H)        (tick space; Δt = seconds since last update)
```

Swaps inside one block share a timestamp, so throughout Δt the price sat at the close of the last block that had swaps, which is exactly the new `snap`. The update is therefore an exact time-weighted geometric mean, not an approximation.

`anchorOf(poolId)` (view): if the stored block is older than `block.number`, compute snap and EMA from `slot0` now; else return stored. One anchor per block for the hook, the Lens and outside takers.

BandGuardV2 passes a fill only if:
- execution price within `bandBps` of the snapshot price, and
- |snap − ema| within `driftBps`.

## 5. Parameters (proposed; V2-11 measures and fixes each with a DECISIONS entry)

| Name | Proposed | Where | Why |
| --- | --- | --- | --- |
| `MAX_STRATEGIES` | 6 | hook constant | bounds reads per swap |
| `MAX_LEGS` | 3 | hook constant | each leg is a router call (~152k gas in v1) |
| `MAX_TICK_RANGES` | 8 | hook constant | bounds the pool walk |
| `MIN_LEG_BPS` | 50 (0.5%) | hook constant | dust legs cost more gas than they save |
| `EMA_HALF_LIFE` | 60 s | hook constant | manipulation cost vs lag |
| `bandBps` | default 200 | maker, strategy bytes | as v1 |
| `driftBps` | default 300 | maker, strategy bytes | largest snap–EMA gap the maker accepts |
| `exclusive` | default true | maker, strategy bytes | only the hook may take |
| `GAS_RESERVE`, `LEG_GAS_CAP` | 150,000 / 640,000 | hook constants | from v1 D-20, re-measured |

## 6. Failure model

Aqua can never make a swap fail. Every failure degrades to the pool.

| Failure | Hook action | Trader result |
| --- | --- | --- |
| Router call reverts or runs out of its gas cap | settle the leg's input back, reset approval, record reason | pool fills that share |
| Maker wallet or allowance short | capped or dropped before solving | split uses the others |
| Maker curve outside band of snapshot | dropped | same |
| Drift limit broken | dropped | same |
| Pool walk reaches 8 ranges | keep that allocation | valid, slightly less optimal |
| Too little gas left | skip all legs | pool-only |
| Maths outside the overflow envelope, or a leg rounds to zero | skip that leg | pool fills it |

## 7. Events

`ConfluenceSwap(poolId, zeroForOne, exactIn, amountSpecified, snapTick, emaTick, sqrtPriceX96, liquidity, swapFee, Leg[] legs)` with `Leg { strategyHash, amountIn, amountOut, status }`. Status codes: FILLED, SKIP_REVERT, SKIP_BAND, SKIP_DRIFT, SKIP_UNDERFUNDED, SKIP_MIN_LEG, SKIP_GAS, SKIP_MATH. Enough to recompute analytics without an archive node. `MakerRegistered`, `MakerUnregistered`, `MakerEvicted(reason)`.

## 8. Deployment shape (Phase 2 deploys; Phase 1 keeps it possible)

Ownerless, no proxy, no hook fee, no required `hookData`. First target Unichain (130): Aqua and the router are listed at the same addresses there [VERIFY router bytecode before relying on it]. Phase 1 tests run on the mainnet fork at `FORK_BLOCK`; V2-05 adds one Unichain fork test.
