# CONFLUENCE v2 gas budget (V2-11)

Every number here was measured with one method, M11, on `FORK_BLOCK` 26349400 (D-01), by `contracts/test/gas/V211Gas.t.sol`. Nothing is estimated. Gas prices and ETH/USD in section 5 are **assumptions** for scale, not live data.

**Method M11.** One `vm.revertToState` snapshot per measurement; the next block (so the swap is the block's first and runs the anchor update); every touched account cooled (manager, hook, both splitters, Aqua, router, USDC and its implementation, MUMB, guard, six makers, trader, `PoolSwapTest`); `gasleft` around the swap sent through `PoolSwapTest`. Run-to-run noise is about 50 gas. Earlier tables (V2-07, V2-09, V2-10) used other methods and are not comparable (D-40).

## 1. Before and after (same method, same sitting)

"Before" is commit `715ff4c` (the M11 test on the code as V2-10 left it); "after" is the final tree. USDC in, 1,000 USDC exact in or 990 MUMB exact out; legs filled are 1 / 3 / 3 for 1 / 3 / 6 makers.

| Swap | before | after | change |
| --- | ---: | ---: | ---: |
| Exact in, 1 maker | 680,049 | 607,308 | -72,741 |
| Exact in, 3 makers | 1,109,900 | 1,037,807 | -72,093 |
| Exact in, 6 makers | 1,343,511 | 1,272,232 | -71,279 |
| Exact out, 1 maker | 691,489 | 604,806 | -86,683 |
| Exact out, 3 makers | 1,145,010 | 1,034,221 | -110,789 |
| Exact out, 6 makers | 1,407,240 | 1,260,014 | -147,226 |
| `planExactIn`, 1 / 3 / 6 makers (cold, direct) | 228,418 / 347,220 / 572,811 | 155,338 / 274,623 / 501,003 | |
| `planExactOut`, 1 / 3 / 6 makers | 239,906 / 382,037 / 636,286 | 152,884 / 270,748 / 488,536 | |

The levers: **1**, the pool walk stops once the segments cover the amount; **2**, exact output loads each maker once (`readOut`); **8**, the hook's reserve follows the pool's work (adds +698 gas exact in and +408 gas exact out on a 1-maker swap). The price is unchanged: M3 is still 991549859869719173233 wei, the M3 mirror and the V2-00 vectors match to the wei (D-40).

## 2. Overhead against pool-only

Pool-only here is the same hooked pool with no makers registered (0 makers); the hookless floor is a v4 pool of the same shape with no hook.

| 1,000 USDC exact in / 990 MUMB exact out | hookless floor | 0 makers | 1 maker | 3 makers | 6 makers (3 legs) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Exact in | 235,986 | 245,675 | 607,308 (+361,633) | 1,037,807 (+792,132) | 1,272,232 (+1,026,557) |
| Exact out | 235,755 | 245,437 | 604,806 (+359,369) | 1,034,221 (+788,784) | 1,260,014 (+1,014,577) |

A leg costs about 215,000 gas (1 -> 3 makers). The hook with no maker adds 9,689 gas to the floor. MUMB in rows: 658,302 / 1,055,598 / 1,305,380 exact in and 655,346 / 1,053,166 / 1,291,039 exact out for 1 / 3 / 6 makers.

### Scenarios (the committed snapshot)

Gapped pool, makers of equal fee. Sizes: exact in small 100 USDC, mid 1,000 USDC, large 2,500 USDC (960 USDC with 0 legs); exact out small 100, mid 250, large 400 MUMB. Crossings are the pool's initialised ticks crossed by the swap. The crossings are as measured: the sizes were fixed per mode, so no scenario crosses 4 ticks and exact out never exceeds 2.

| Legs | size | exact in gas (crossings) | exact out gas (crossings) |
| --- | --- | ---: | ---: |
| 0 | small | 245,604 (0) | 244,792 (0) |
| 0 | mid | 466,864 (7) | 280,621 (1) |
| 0 | large | 466,955 (7) | 311,280 (2) |
| 1 | small | 607,131 (0) | 604,199 (0) |
| 1 | mid | 746,778 (1) | 615,917 (0) |
| 1 | large | 960,756 (5) | 627,589 (0) |
| 2 | small | 821,054 (0) | 817,626 (0) |
| 2 | mid | 972,721 (1) | 829,508 (0) |
| 2 | large | 1,103,099 (3) | 841,084 (0) |
| 3 | small | 1,036,294 (0) | 1,031,840 (0) |
| 3 | mid | 1,116,565 (0) | 1,044,235 (0) |
| 3 | large | 1,276,879 (2) | 1,055,949 (0) |

`contracts/.gas-snapshot` holds these 24 plus `worstCaseBelowCeiling`. CI fails when any moves by more than 5% (section 7).

## 3. Price gain over pool-only

The v1 pool, exact in, from one snapshot per size: the same swap with the makers unregistered. MUMB out; gain valued in USDC at the pool-only price (size / pool-only out).

| USDC in | Makers | Hooked | Pool-only | Gain | Extra gas |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 500 | 1 | 497.134 | 495.465 | +1.669 MUMB (33.7 bps, $1.68) | 361,444 |
| 1,000 | 1 | 991.550 (M3) | 984.934 | +6.616 (67.2 bps, $6.72) | 361,576 |
| 2,000 | 1 | 1,972.318 | 1,946.314 | +26.004 (133.6 bps, $26.72) | 360,656 |
| 5,000 | 1 | 2,500.000 | 2,500.000 | 0 (no leg: the walk does not cover the amount, pool-only) | 173,975 |
| 500 | 3 | 497.504 | 495.465 | +2.039 (41.1 bps, $2.06) | 791,736 |
| 1,000 | 3 | 993.031 | 984.934 | +8.097 (82.2 bps, $8.22) | 791,880 |
| 2,000 | 3 | 1,978.460 | 1,946.314 | +32.146 (165.2 bps, $33.03) | 791,980 |
| 5,000 | 3 | 4,890.498 | 2,500.000 | the pool alone fills only 2,500 MUMB (its range ends); with makers the swap fills 4,890.498 | 444,783 |

At 5,000 USDC the v1 pool's liquidity ends and the pool-only swap is a partial fill; the "gain" there is a fill, not a price.

## 4. Break-even gas price (assumptions)

Break-even gas price = gain in USD / (extra gas x ETH/USD). **ETH/USD of 2,000, 3,000 and 4,000 are assumptions. No price was fetched.** The result is a gas price in gwei: compare it with the chain's price when you decide.

| USDC in | Makers | break-even gwei at ETH/USD 2,000 / 3,000 / 4,000 |
| ---: | ---: | --- |
| 500 | 1 | 2.33 / 1.55 / 1.16 |
| 1,000 | 1 | 9.29 / 6.19 / 4.64 |
| 2,000 | 1 | 37.05 / 24.70 / 18.52 |
| 500 | 3 | 1.30 / 0.87 / 0.65 |
| 1,000 | 3 | 5.19 / 3.46 / 2.60 |
| 2,000 | 3 | 20.85 / 13.90 / 10.43 |

**Unichain and Ethereum mainnet.** Both rows above are the same number: the break-even is a gas price, and the hook adds only execution gas (a swap's calldata is identical with or without the hook: `hookData` is empty), so the L1 data fee on Unichain does not change. Which chain is cheaper than break-even is a question for that chain's price on the day; this document does not state typical prices (no verified source). For scale: 1,000 USDC with one maker breaks even at about 6 gwei at the assumed ETH/USD of 3,000.

## 5. Your gas limit: do not use `eth_estimateGas` alone (integrators, wallets, the Phase 3 UI)

The hook skips every leg when the gas left at `beforeSwap` is below `RESERVE_MAX + MIN_LEG_GAS` = **1,290,000** (D-40); the swap still passes and the trader gets the pool-only fill (`SKIP_GAS` in the event). A node's `eth_estimateGas` returns the lowest limit at which the swap passes, which is a pool-only limit. Send

`gasLimit = max(eth_estimateGas, Lens.minHookGas + the pool's share)`

(`Lens.quote(...).minHookGas` is a sufficient bound, now 2,165,265 / 2,957,790 / 3,754,847 for 1 / 2 / 3 legs; it was 1,278,346 / 2,070,634 / 2,867,443 before V2-11) or legs are skipped. Measured with the estimator probe (gas used at a high limit, retried at used x 64/63 and used x 64/63 + 50,000, then a binary search from 21,000), legs filled out of the legs the swap fills with plenty of gas:

| Fixture | used at high limit: main / V2-11 | legs at used x 64/63: main / V2-11 | at +50,000: main / V2-11 | binary search |
| --- | --- | --- | --- | --- |
| 1 maker, exact in | 668,556 / 671,389 | 0 / 0 | 1 / 0 | pool-only in both |
| 1 maker, exact out | 677,819 / 666,702 | 0 / 0 | 1 / 0 | pool-only |
| 3 makers, crossing pool, exact in | 1,196,633 / 1,200,408 | 2 / 0 | 2 / 0 | pool-only |
| 3 makers, crossing pool, exact out (no leg fills: walk truncated) | 1,693,251 / 1,657,755 | 0 / 0 | 0 / 0 | pool-only |
| 3 makers, no crossing, exact in | 1,033,399 / 960,247 | 2 / 0 | 2 / 0 | pool-only |
| 3 makers, no crossing, exact out | 1,067,535 / 955,742 | 2 / 0 | 2 / 0 | pool-only |
| 6 makers (3 legs), exact in | 1,268,055 / 1,196,750 | 2 / 0 | 2 / 0 | pool-only |
| 6 makers (3 legs), exact out | 1,331,320 / 1,184,095 | 2 / 0 | 2 / 0 | pool-only |

On `main`'s hook (gate 330,000) the estimator's limit already skipped part of the legs (the third); with V2-11's gate it skips all of them. Every swap in this table passed in every cell.

## 6. Known costs and the limit of "never reverts"

- **Reading six makers to fill three costs 234,425 gas** (6 makers 1,272,232 against 3 makers 1,037,807 exact in): the three that are dropped are still read and priced. A known cost and a possible future lever (D-42); not taken.
- **A 3-maker exact-in swap lands at 1,037,807 gas**, not under 1,000,000: that goal needs a dropped leg (about 215,000 gas); not taken (D-43).
- **Never reverts where pool-only passes, if the pool's own path fits the walk bound** (the walk covers the amount within `MAX_TICK_STEPS` steps). Fixtures 0, 2 and 3 (1 or 3 makers, no crossings, and the v1 pool with 6 makers) and fixture 4 (the gapped pool with 3 makers, 3 to 4 pool crossings inside the walk bound) have no failing gas limit in any variant. On a pool that crosses more ticks than the walk reads, the pool alone needs more than the hook's `RESERVE_MAX`; a window of gas limits (fixture 1: 1.5M to 1.7M exact in, 1.5M to 1.6M exact out; up to 3M with a burning guard or splitter) remains where a hooked swap reverts and pool-only passes. It is pinned by a test; any widening fails (D-40).
- **Worst cases (ceilings, D-47):** honest 6 makers, 3 legs: 1,371,000 at most; hostile: three burning legs 2,787,000, a burning splitter 1,967,000; analytic bound 4,530,000, under EIP-7825's 16,777,216 transaction cap. The bound uses the hook work measured on the v1 pool (1 walk step); a pool that costs more on its own (fixture 1: about 1.31M) is not covered by that figure.
- **Sizes:** hook 20,993 B (limit 24,576), Splitter 21,504, SplitterOut 21,079, Lens 13,606 (limit 24,076 for the splitters).

## 7. The regression check

`forge snapshot --check --tolerance 5` over `test_V211_snap_*` and `test_V211_worstCaseBelowCeiling` (no fuzz test) against `contracts/.gas-snapshot`; `.github/workflows/gas.yml` runs it on push to `main` and on pull requests. Expected RPC use per CI run, counted through a local proxy: 206 requests with a cold cache (174 `eth_getStorageAt`, 24 `eth_getAccountInfo`, 8 other), 5 with a warm one (the cache is keyed on `FORK_BLOCK`). The job needs the repository secret `MAINNET_RPC_URL` (added by the repository owner) and skips with a visible warning without it.
