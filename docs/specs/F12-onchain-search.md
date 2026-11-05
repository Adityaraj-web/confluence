# F12 On-chain bounded search (stretch)

- Owner: T2
- Depends on: F06 (and everything Must in FEATURES.md Done)
- Decisions: D-05

## Goal
With empty `hookData`, the hook finds a good Aqua slice by itself, with a fixed gas budget.

## Files
- `contracts/src/ConfluenceHook.sol`
- `contracts/src/libraries/SplitSearch.sol`
- `contracts/test/fork/F12Search.t.sol`

## Behaviour
- Bisection on the Aqua amount over a fixed number of steps (start with 8): at each step compare Aqua's marginal output (via router `quote`, wrapped in try/catch) with the pool's marginal output for the same small slice (read from pool state; no external quoter).
- If any quote reverts, treat that size as unavailable and search lower.
- Then run the F05 path with the found amount.

## Acceptance
- `test_F12_searchWithinOnePercentOfQuoter`: the on-chain choice gives output within 1% of F07's best hint for 3 trade sizes.
- `test_F12_gasBounded`: gas for `beforeSwap` with search stays under a recorded ceiling (measure, then fix the number in the test).
- All F05 and F06 tests still pass with empty `hookData`.
