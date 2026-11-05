# F07 Off-chain quoter

- Owner: T2
- Depends on: F05
- Architecture: section 7

## Goal
Pick the best hint for a trade by simulation, so the demo and web app always send a good split.

## Files
- `scripts/src/quoter.ts`
- `scripts/src/config.ts` (addresses from `.env` and the deployment output of F09)
- `scripts/src/abis/` (generated from forge artifacts, not hand-written)
- `scripts/test/quoter.test.ts`

## Behaviour
- `bestHint({ poolKey, zeroForOne, amountIn, from })` returns `{ hint, poolOnlyOut, splitOut, aquaShare }`.
- Simulates the trader's full swap with `eth_call` (viem `simulateContract`) for hints 0%, 10%, ..., 100%, then checks 5 points between the best two.
- Treats a reverted simulation as unusable, not as zero output.
- CLI: `pnpm --dir scripts quote --amount 1000 --dir usdc-to-mumb` prints a small table.

## Out of scope
On-chain search (F12). Gas optimisation.

## Acceptance
- Against a running anvil set up by F09's script (or the F05 test state exported), `quote --amount 1000` prints a hint with `splitOut > poolOnlyOut`.
- `quoter.test.ts`: hint 0 equals the pool-only path; the chosen hint's output is the maximum of all simulated points.
- Typecheck passes.
