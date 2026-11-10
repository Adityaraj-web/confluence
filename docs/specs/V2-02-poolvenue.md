# V2-02 PoolVenue

- Owner: Adityaraj
- Depends on: V2-01
- Branch: `v2/02-poolvenue`
- Architecture: ARCHITECTURE-v2 sections 2 (step 3), 3 (pool paragraph)

## Goal
Turn the live v4 pool into segments the solver can use, including tick crossings, so the split stays right for large trades.

## Files
- `contracts/src/libraries/PoolVenue.sol`
- `contracts/src/libraries/SplitMath.sol` (piecewise pool venue)
- `contracts/test/fork/V202PoolVenue.t.sol`

## Behaviour
- Read via `StateLibrary`: `getSlot0` (sqrtPrice, tick, protocolFee, lpFee), `getLiquidity`, `getTickBitmap`, `getTickLiquidity`.
- Fee factor from v4's combined swap fee (`ProtocolFeeLibrary.calculateSwapFee`), as the PoolManager charges it.
- Walk initialized ticks in the swap's direction with `TickBitmap.nextInitializedTickWithinOneWord`; at most `MAX_TICK_RANGES` (8) segments: liquidity, start and end sqrtPrice, input to cross, output from crossing (v4 `SqrtPriceMath`).
- Stop at the trader's `sqrtPriceLimitX96`.
- `SplitMath.solveExactIn/Out` accept the pool as a piecewise venue and re-solve per crossed segment (ARCHITECTURE-v2 section 3).
- Read-only: no state writes.

## Out of scope
Hook wiring (V2-07).

## Acceptance
- `test_V202_singleRangeMatchesSwap`: predicted pool output for a given input equals a real pool-only swap within 2 wei, both directions.
- `test_V202_crossesTicks`: 3 overlapping positions, a trade crossing 3 ticks; prediction equals the real swap within 2 wei per crossing.
- `test_V202_respectsPriceLimit`: both directions; the segment list ends at the limit.
- `test_V202_walkLimitFallback`: 10 initialized ticks in the path; 8 segments returned, allocation valid, swap does not revert.
- `test_V202_splitWithCrossingMatchesVectors`: pool + 1 maker, crossing case, against V2-00.
