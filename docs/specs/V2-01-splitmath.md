# V2-01 SplitMath

- Owner: Adityaraj
- Depends on: V2-00
- Branch: `v2/01-splitmath`
- Architecture: ARCHITECTURE-v2 section 3
- Decisions: add one for the overflow envelope and the rounding rule

## Goal
A pure library that splits a trade across up to 8 constant-product venues for the best result, exact input and exact output, with a cap per venue.

## Files
- `contracts/src/libraries/SplitMath.sol`
- `contracts/test/unit/V201SplitMath.t.sol`

## Behaviour
- `struct Venue { uint256 x; uint256 y; uint32 feeE9; uint256 cap; }` (cap in input units for exact input, output units for exact output; `type(uint256).max` = none).
- `solveExactIn(Venue[] memory v, uint256 amountIn) returns (uint256[] memory a)` and `solveExactOut(Venue[] memory v, uint256 amountOut) returns (uint256[] memory b)`.
- Active set by starting rate; capped venues pinned and the rest re-solved; at most `v.length` passes; `v.length <= 8`.
- `FullMath.mulDiv` everywhere a product can exceed 256 bits; integer sqrt (floor) on 512-bit-safe inputs.
- Rounding: maker amounts floor; `a[last]` (by convention the pool, index 0) is `amountIn − Σ others`, so the parts sum exactly.
- Overflow envelope written in NatSpec: reserves and amounts `< 2^128`. Outside it, return all maker amounts zero (pool-only). Never reverts.
- Pure: no storage, no external calls.

## Out of scope
Tick crossings (V2-02). Any hook wiring.

## Acceptance
- `test_V201_matchesVectors`, `test_V201_exactOutMatchesVectors`: relative error < 1e-9 against V2-00 vectors.
- `testFuzz_V201_sumEqualsAmount`, `testFuzz_V201_respectsCaps`.
- `testFuzz_V201_neverWorseThanAnySingleVenue`: split output >= best single-venue output minus `v.length` wei.
- `testFuzz_V201_equalMarginals`: uncapped active venues end with marginals equal within 1e-6 relative.
- `testFuzz_V201_neverReverts` across the full uint range (returns pool-only outside the envelope).
- `test_V201_gasCeiling`: 4 venues; ceiling recorded in the test and in PROGRESS.
