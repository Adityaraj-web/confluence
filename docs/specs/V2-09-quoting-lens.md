# V2-09 Quoting parity and ConfluenceLens

- Owner: Adityaraj
- Depends on: V2-07, V2-08
- Branch: `v2/09-lens`
- Architecture: ARCHITECTURE-v2 sections 1, 7

## Goal
Every quote equals what the swap delivers, and apps can see why.

## Files
- `contracts/src/ConfluenceLens.sol`
- `contracts/test/fork/V209Quoting.t.sol`
- `contracts/test/base/ForkBase.t.sol` (deploy v4-periphery's `V4Quoter` on the fork if it is not deployed at FORK_BLOCK [VERIFY])

## Behaviour
- V4Quoter simulates the real swap, so the hook runs inside it; this spec proves parity.
- `quote(PoolKey key, bool zeroForOne, int256 amountSpecified) returns (Breakdown)`: per venue amount in and out, pool-only result, anchor (snap, ema), per-maker status, gain in bps.
- Maker outputs come from `MakerVenue` maths (mirrors SwapVM rounding), not the router's `quote`: an exclusive strategy refuses the Lens as taker.
- `makerLimits(PoolKey key) returns (MakerLimit[])`: caps and reasons for solvers and indexers.
- Same libraries as the hook; never called during a swap; no state.

## Out of scope
Any UI.

## Acceptance
- `test_V209_v4QuoterEqualsSwap`, `test_V209_lensEqualsSwap`: exact in and out, both directions, to the wei.
- `test_V209_lensPoolOnlyEqualsUnhookedSwap`.
- `test_V209_lensReportsEachStatus`: FILLED and every SKIP code reached.
