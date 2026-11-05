# F08 Invariant and fuzz tests

- Owner: T1
- Depends on: F06
- Architecture: section 4

## Goal
Show judges, with tests, that the books always balance and the band keeps Priya safe even when Aqua fills everything.

## Files
- `contracts/test/invariant/ConfluenceInvariants.t.sol`
- `contracts/test/invariant/handlers/ConfluenceHandler.sol`

## Behaviour
Handler actions: trader swaps with random size, direction and hint; an arbitrageur swaps pool-only to move the price; Priya docks and re-ships.

## Acceptance
Invariants (run with a fixed seed and the default run count; record the counts in PROGRESS.md):
- `invariant_F08_hookHoldsNothing`
- `invariant_F08_makerValueConserved`: Priya's wallet change equals her Aqua virtual balance change for each token
- `invariant_F08_noAquaFillOutsideBand`: every `AquaFill` event's execution price is within the band of the pool price at that moment
Fuzz tests:
- `testFuzz_F08_splitNeverWorseThanPoolOnly` for hints chosen by a simple on-test grid (bounded amounts)
- `testFuzz_F08_fullAquaFillAnchorRecovers`: after many 100% Aqua fills, one arbitrage swap brings the pool price back within the band, and Aqua fills resume

## Note
If an invariant fails, keep the failing sequence in the test file as a regression test before fixing.
