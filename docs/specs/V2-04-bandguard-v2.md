# V2-04 BandGuardV2

- Owner: Adityaraj
- Depends on: V2-03
- Branch: `v2/04-bandguard`
- Architecture: ARCHITECTURE-v2 sections 1, 4; v1 ARCHITECTURE section 5 for the register layout

## Goal
The maker's own guard, checked against the hook's anchor instead of spot, with an optional rule that only the hook may take.

## Files
- `contracts/src/BandGuardV2.sol`
- `contracts/test/unit/V204BandGuard.t.sol`
- `contracts/test/fork/V204BandGuardFork.t.sol`

## Behaviour
- Same contract rules as `PoolPriceBandExtruction`: stateless, non-upgradeable, no owner, no storage, one `view` `extruction` serving quote and swap, never writes swap amounts, reverts or returns registers unchanged.
- Args = v1's 88 bytes + `uint16 driftBps` + `uint8 flags` (bit 0 = exclusive) = 91 bytes. `build(...)` and `parse(...)` helpers in a library the template uses.
- Check order: args length and ranges; tokens match the pool key; if exclusive, `query.taker == address(key.hooks)` else revert `TakerNotHook`; read `IConfluenceHook(key.hooks).anchorOf(poolId)`; `|snap − ema| <= driftBps` else `AnchorDrift`; registers computed (not zero); execution price within `bandBps` of the snapshot price else `BandExceeded(exec, ref, bandBps)`.
- Tick-to-price via `TickMath.getSqrtPriceAtTick` and `FullMath`; no overflow near the tick bounds.
- `PoolPriceBandExtruction` stays in the repo untouched for v1 tests.

## Out of scope
The registry (V2-05).

## Acceptance
- `test_V204_exclusiveRefusesOtherTakers`, `test_V204_openAllowsAnyTaker`.
- `test_V204_driftRefusal`.
- `test_V204_bandUsesSnapshotNotSpot`: move `slot0` inside one block; the band still measures from the snapshot.
- `test_V204_quoteEqualsSwapWithinBlock`.
- `test_V204_v1BandCasesHold`: v1 F03 cases ported with the snapshot as reference.
- `test_V204_argsRoundTrip`, `test_V204_badArgsRevert`.
