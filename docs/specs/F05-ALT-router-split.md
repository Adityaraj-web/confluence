# F05-ALT Router-level split (fallback)

- Owner: T1 + T2
- Depends on: F03, F04
- Build only if F05 misses the hour-8 gate (record the decision in FEATURES.md gate log).
- Architecture: section 9

## Goal
Keep both prizes alive by doing the split outside the hook: one transaction swaps part on Aqua and the rest on the v4 pool.

## Files
- `contracts/src/SplitRouter.sol`
- `contracts/test/fork/F05AltSplitRouter.t.sol`

## Behaviour
- `swapSplit(poolKey, zeroForOne, amountIn, aquaAmountIn, minOut)`:
  1. Pull `amountIn` from the trader.
  2. Swap `aquaAmountIn` through the canonical AquaSwapVMRouter (Priya's order looked up from a registry stored in SplitRouter) with pay-by-transfer. The band Extruction still runs inside her program.
  3. Swap the rest through the v4 pool (unlock callback).
  4. Require total out >= `minOut`; send it to the trader.
- Aqua failure falls back to a pool-only swap of the full amount (try/catch).
- The hook stays attached but does nothing.

## Out of scope
Anything in the hook.

## Acceptance
- `test_F05ALT_splitBeatsPoolOnly`, `test_F05ALT_aquaFailureFallsBack`, `test_F05ALT_noResidualBalances` (SplitRouter holds zero after each swap).
