# F06 Safety: try/catch unwind and skip cases

- Owner: T1
- Depends on: F05
- Architecture: section 3 (last paragraph), section 4
- Decisions: D-06

## Goal
Aqua can never make a swap fail. Any failure in the Aqua leg unwinds cleanly and the pool fills the whole swap.

## Files
- `contracts/src/ConfluenceHook.sol`
- `contracts/test/fork/F06Safety.t.sol`

## Behaviour
- Wrap the router call in try/catch.
- On catch: settle the `a` input back to the PoolManager (the hook took it in step 2), reset the approval, emit `AquaSkipped(poolId, reason)` with the revert data, return a zero delta.
- A hint larger than Priya's available Aqua balance is caught the same way.
- Gas: forward enough gas that a revert inside the router is caught rather than running the whole swap out of gas; document the choice.

## Out of scope
New features. Pure robustness.

## Acceptance
Each test asserts: swap succeeds, trader output equals the pool-only output from the same snapshot, hook balances zero, Priya's wallet unchanged, `AquaSkipped` emitted.
- `test_F06_bandBreachFallsBack` (pool price moved outside band)
- `test_F06_dockedStrategyFallsBack` (Priya called `dock`)
- `test_F06_insufficientMakerBalanceFallsBack` (hint larger than her virtual balance)
- `test_F06_makerRevokedApprovalFallsBack` (Priya set Aqua approval to zero)
- `test_F06_unregisteredOrderIsPoolOnly`
