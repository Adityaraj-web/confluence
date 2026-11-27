# CONFLUENCE v2 threats (V2-10)

One row per attack. Every test name is in `contracts/test/attack/` (the v1 ones in `test/attack/v1/`). PnL is in raw USDC (6 decimals) with MUMB valued at the block-start price of 1 USDC, unless said otherwise. Decisions behind the rows: D-38 (the suite), D-39 (the hook fixes from the hostile-token tests).

## Hook permission view

`getHookPermissions` sets `beforeSwap` and `beforeSwapReturnDelta` only. The returns-delta flag is the highest-risk class in Uniswap's view: the hook can take or give any amount of either token. What bounds it: every delta is built from the legs the hook actually filled and the balance difference it measured (`ConfluenceHook.sol` `_legs`); the hook holds zero tokens after every swap; the PoolManager must net to zero (a swap that returns proves it); `beforeSwap` never overrides the LP fee; there is no owner, admin, proxy or fee switch. The hook calls out to: the splitter (immutable, `staticcall` with a gas cap and an exact length check), the canonical router (inside `try/catch`, gas-capped), the PoolManager, and the two tokens of the pool (`transfer`, `approve`).

## Scenarios

| # | Attacker | Asset at risk | Path | Defence | Test | Residual risk |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Anyone who can move the pool inside a block | A maker's stale-priced inventory | Push spot, fill the maker whose band follows spot, swap back | `BandGuardV2` reads the block's first snapshot (anchor), never spot. v1 read spot: the attack pays | v2 `A01SameBlock.test_V210_sameBlockPush`, `testFuzz_V210_sameBlockPush` (1,000 runs); `V204BandGuardFork.test_V204_sameBlockAttackRefused` (the same fill reverts `BandExceeded`). **v1:** `v1/A01V1SameBlock.test_V210_v1SameBlockPushPaysTheAttacker`: attacker **+29.641527**, Priya **-38.574122** | v2: maker PnL >= 0 in all six fixed cases (+4.98 to +15.26). The victim's own slippage can be sandwiched as on any AMM (attacker +0.50 to +9.20 with the maker, +1.85 to +15.83 against the pool alone, one case reversed, D-38); the victim is never worse than pool-only from the manipulated state |
| 2 | A holder of capital across a block | A maker's inventory | Push in block N, leave it; the next block's snapshot is the pushed price; fill; unwind | The EMA moves 12.94% of the gap per 12 s block, so drift = 0.8706 of the pre-update gap; a 300-tick `driftTicks` pauses the maker from about 344 ticks; the band holds each fill within 2% of the snapshot | `A02CrossBlock.test_V210_crossBlockPause` | Attacker PnL -123.4 to -136.9 in all seven pushes (50 to 600 ticks); maker +46.97. The window a maker can lose in is the band (2%) plus at most the drift limit's worth of displacement, and only against capital held across a block |
| 3 | The market | A stale maker | A real move; the curve is old | Off-market curves are dropped (`SKIP_DRIFT`, then `SKIP_BAND`); nothing moves | `A03StaleMaker.test_V210_staleMakerOutsideTheBandIsSkipped`, `test_V210_staleMakerInsideTheBandLosesAtMostTheBand` | Inside the band a stale maker fills: a 100 USDC fill after a 1.2% move cost it 0.80 USDC (bound 2%). That is the band, by design |
| 4 | A maker | Other makers' and the trader's swap | Phantom virtual balance, drained wallet, revoked allowance, docked strategy | Depth is `min(virtual, wallet, allowance)` before allocation; a bad maker is `SKIP_UNDERFUNDED` | `A04Phantom` (4 tests) | none found: the swap equals pool-only, books exact |
| 5 | A maker | Swap gas | A guard that burns gas | A foreign program cannot register (D-33, `StrategyNotShipped`); a registered burner is cut at `LEG_GAS_CAP` | `A05GasBurn` (2 tests) | A burning leg costs 640,000 plus 156,173 gas of hook work; three of them add 2.39M gas to a swap that would have cost 240k. Wallets need `eth_estimateGas`, not the pool-only figure. Not evictable: the cap bounds it and the swap still fills from the pool |
| 6 | Anyone | A maker's slot | Spam, phantom-depth eviction, flash-loaned depth | Real depth only; a newcomer must exceed the smallest slot strictly. v1 had one slot that anyone could overwrite | `A06Registry` (2 tests); **v1:** `v1/A06V1Displacement`: displacer **+19.704921** as the maker, victim gets 980.295 MUMB instead of 987.158 | **Open (D-38):** flash-loaned depth evicts the smallest real maker for gas only; no value moves; anyone can `evict` the emptied slot and the victim can register again. Needs a design change (stake, delay or minimum age): V2-12 |
| 7 | A maker or a splitter | Swap gas | A 500 kB revert or a 100 kB return | `catch {}` binds no data; the splitter's return is read only if exactly `PLAN_BYTES` | `A07RevertBomb` (2 tests) | Gas with a 500 kB revert is the same as with none (737,447 against 737,672) |
| 8 | A trader | A maker's rounding | Swaps of 1 to 999 raw units, both directions, repeated | Legs under `MIN_LEG_BPS` skipped; the fee rounds up, the output down | `A08Dust` | 12 dust legs filled, 41 skipped as too small, in 60 swaps; the maker's value did not fall |
| 9 | A token or a contract maker | The hook's books | Re-entry through a call-out in `transfer`, `approve`, the router call | See "Hostile tokens" below. The PoolManager is **not** locked while the hook runs (D-38); the defences are the per-order and per-strategy locks, the hook's transient lock (D-39), exact approvals reset to 0, and a `view` guard | `A09Reentry` (17 tests) | See below |
| 10 | A contract taker | A maker's exclusive strategy | Call the router directly to fill or quote | `BandGuardV2`'s exclusive flag: `TakerNotHook` | `A10Exclusive` | PnL 0 on both sides; nothing moves |
| 11 | A fast market | Maker availability | Make makers pause after a move | The drift limit | `A11EmaLag` | A maker re-centred after a 550-tick move waits 53 s (60 s at 12 s blocks); after 953 ticks 101 s. The defence's cost, recorded |

## Wide-domain arithmetic and the EMA cut-off (carry-overs)

- **Band caps, 50,000 runs each, no RPC** (`A12BandCaps`): exact-input caps and exact-output caps pass the real guard at every fill the test names, across four tick strata (today's domain, 300,000 to 429,800, 429,800 to the top tick, the negative far side), makers of 1 to 3 wei included; `caps` and `capsOut` never revert for any word in the arguments within the template's domain. Pinned outside it: `bandBps` above 10,000 and `outCap = 2^256 - 1` panic; neither is reachable on chain (D-38).
- **EMA cut-off** (`A13EmaJump`): the jump at 16 half-lives is 27.39 ticks at the full range, bounded by `gap * 1.0117 / 2^16`, 50,000 runs. It can only change the drift decision of a maker whose `driftTicks` is under 28.
- **Splitter trust** (`A14HostileSplitter`): `PlanCheck` refuses wrong sums, caps, codes, slots, overflow, a truncated walk, a plan that is not better, too many legs and an over-large PoolManager total, in both modes, and the Lens refuses the same plans. It cannot recompute `poolOnlyOut` or `poolOut`: a plan that lies about them passes (pinned: 984.871110 against 984.934195 MUMB). The guarantee "never worse than the pool alone" is the splitter's; the hook's constructor binds it (D-35), so verifying a deployment includes verifying the splitter's bytecode.
- **Price limit** (`A15PoolEdges`): when the makers take the whole exact-input amount, a `sqrtPriceLimit` on the wrong side does not revert (`Pool.sol:320` returns first); exact output does revert, as the pool alone does. Never worse on a truncated walk with thin makers: 3,000 runs per mode.

## Hostile tokens (a pool the attacker creates with the token; no honest pool is affected)

The hook keeps no cross-pool token state and holds nothing between swaps, so a hostile token can only hurt the swaps of its own pool. "Standard" means an ERC-20 as USDC and USDT behave (USDT returns nothing from `transfer`, `transferFrom` and `approve`, and its `approve` reverts from non-zero to non-zero).

| Behaviour | Before D-39 | After D-39 | Funds moved | Hook balance, allowances |
| --- | --- | --- | --- | --- |
| Re-entry: a swap inside a leg (router call or the hook's own `approve`), same pool or a second hooked pool | Outer approval zeroed by the inner reset, legs `SKIP_REVERT`, pool fills | The inner swap reverts `Reentered`; outer legs fill | n | 0, 0 |
| Re-entry: `unregister`, `register`, `evict` mid-leg (H1) | Swap REVERTED (out of bounds) | Rejected `Reentered`; legs fill | n | 0, 0 |
| `pm.take` by the token | Reverts `CurrencyNotSettled`; nothing moves | same | n | 0, 0 |
| Donation inside the balance window | Only the donor pays | same | the donor's own | 0, 0 |
| USDT-shaped token, either side (H4) | Swap REVERTED (`CurrencySettler` decodes a `bool`) | Passes, legs fill, a failed leg settles back | n | 0, 0 |
| Issuer blocklists the hook, token is the input (H5) | Swap REVERTED | `take` in `try/catch`: legs `SKIP_REVERT`, pool fills (equal to pool-only, both modes) | n | 0, 0 |
| Issuer blocklists the hook, token is the output | Leg fails inside `try/catch`, pool fills | same | n | 0, 0 |
| Issuer blocklists a maker | Leg `SKIP_REVERT` | same | n | 0, 0 |
| **Residual** fee-on-transfer, output side | REVERT at `unlock` (pool-only passes) | same, pinned | n | 0, 0 |
| **Residual** fee-on-transfer, input side | REVERT (pool-only reverts too: v4 itself) | same, pinned | n | 0, 0 |
| **Residual** token that reverts on `approve(0)` (H3) | REVERT | same, pinned | n | 0, 0 |
| **Residual** ERC-777/1363-style callbacks into other contracts | n/a | The lock covers calls into this hook; what other contracts do is theirs | n | 0, 0 |

Pinned tests: `test_V210_pinned_feeOnTransferOutputReverts`, `test_V210_pinned_feeOnTransferInputReverts`, `test_V210_pinned_approveZeroRevertReverts`. Each residual reverts only that pool's legged swaps, moves no funds and leaves the hook with zero balance and zero allowances. A fee-on-transfer shortfall shows at `unlock` after the hook has returned, so no try/catch inside the hook can catch it; a wrapper around the whole leg stage (variant (c), +1,800 B and about +11,000 gas per legged swap) would cover H3 but not that, and was not taken.

## Other recorded behaviour

- **v1 comment and spec premise:** see D-38 (scenario 9, `ConfluenceHookV1.sol:207`).
- **Sandwiching:** an attacker can sandwich a trader's slippage on this pool as on any AMM. The hook does not make it worse for the trader (never worse than pool-only from the same state) and it is not a maker loss.
