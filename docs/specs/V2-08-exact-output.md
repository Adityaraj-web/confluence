# V2-08 Exact output

- Owner: Adityaraj
- Depends on: V2-07
- Branch: `v2/08-exactout`
- Architecture: ARCHITECTURE-v2 sections 2 (step 6), 3
- Decisions: D-08 superseded

## Goal
"I want exactly B tokens" swaps get the blended price too, in both directions.

## Files
- `contracts/src/ConfluenceHook.sol`
- `contracts/test/fork/V208ExactOut.t.sol`

## Behaviour
- `amountSpecified > 0`: `SplitMath.solveExactOut`.
- Each leg calls the router with `isExactIn = false` for its output `b_i`; the hook first computes the input the leg needs with SwapVM's ceiling rounding, takes it, and passes it as a strict threshold so the router can never charge more. Unused input is settled back.
- Delta: specified `−Σb`, unspecified `+Σa`. Write the sign test first, red, against OpenZeppelin `BaseCustomCurve`'s convention, before any leg code.
- Same safety and event as V2-07.

## Out of scope
Anything new on exact input.

## Acceptance
- `test_V208_deltaSignsNet` (written first).
- `test_V208_exactOutBothDirections`.
- `test_V208_minimisesInput`: input <= pool-only input for the same output, and within rounding of V2-00.
- `test_V208_strictThreshold`: a leg needing more than its threshold is skipped, not overcharged.
- `test_V208_legFailureFallsBack`, `test_V208_hookHoldsNothing`.
