# V2-07 Hint-free split in beforeSwap

- Owner: Adityaraj
- Depends on: V2-01, V2-02, V2-03, V2-06
- Branch: `v2/07-split`
- Architecture: ARCHITECTURE-v2 sections 2, 6, 7
- Decisions: D-08, D-20 (re-measured); add one for library linking from the contract size

## Goal
Every exact-input swap on the pool, in either direction, gets the best split with no hint.

## Files
- `contracts/src/ConfluenceHook.sol`
- `contracts/test/fork/V207Split.t.sol`
- `scripts/src/quoter.ts` (kept only as a test cross-check; not used by the demo)

## Behaviour
- ARCHITECTURE-v2 section 2 steps 1-7 for `amountSpecified < 0`, both `zeroForOne` values. `hookData` is ignored whatever it holds.
- Legs under `MIN_LEG_BPS` dropped; at most `MAX_LEGS` maker legs (largest kept); the dropped share re-solved onto the rest.
- Per leg, v1's safety kept: exact approval reset to zero, try/catch, `GAS_RESERVE` kept back, `LEG_GAS_CAP`, revert data trimmed to 256 bytes.
- Anchor updated before any leg runs.
- One `ConfluenceSwap` event (ARCHITECTURE-v2 section 7). v1's `AquaFill` / `AquaSkipped` removed.
- Hook holds zero tokens after every swap.
- Measure the hook's deployed size; decide internal vs linked libraries; DECISIONS entry.

## Out of scope
Exact output (V2-08). The Lens (V2-09).

## Acceptance
- `test_V207_emptyHookDataGetsSplit`.
- `test_V207_atLeastV1Best`: 1,000 USDC in -> >= 991549823315669231761 wei MUMB, empty `hookData`.
- `test_V207_bothDirections`.
- `test_V207_threeMakersMatchVectors`: realised legs match V2-00 within rounding.
- `test_V207_failedLegFallsToPool`: one maker's router call reverts (`vm.mockCallRevert` on the router for that order); swap succeeds, pool fills that share, status SKIP_REVERT.
- `test_V207_hookHoldsNothing`, `test_V207_noMakersIsPoolOnly`, `test_V207_neverWorseThanPoolOnly` (fuzz sizes and directions, same snapshot).
