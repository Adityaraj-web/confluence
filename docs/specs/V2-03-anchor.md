# V2-03 Anchor

- Owner: Adityaraj
- Depends on: V2-00
- Branch: `v2/03-anchor`
- Architecture: ARCHITECTURE-v2 section 4
- Decisions: add one for the fixed-point format and the exp2 method

## Goal
A reference price no single transaction can move: the block-start snapshot, plus a time-weighted EMA that makes cross-block pushes expensive.

## Files
- `contracts/src/libraries/AnchorLib.sol`
- `contracts/src/ConfluenceHook.sol` (new v2 hook: permissions `beforeSwap` + `beforeSwapReturnDelta` like v1; this spec adds only anchor storage, the update at the top of `beforeSwap`, `anchorOf`; `beforeSwap` otherwise returns pool-only)
- `contracts/test/base/ForkBase.t.sol` (deploy and mine the v2 hook address next to v1's)
- `contracts/test/fork/V203Anchor.t.sol`

## Behaviour
- One packed slot per pool: `uint40 lastTimestamp`, `uint64 lastBlock`, `int24 snapTick`, `int56 emaTickX` (tick × 2^16).
- First `beforeSwap` in a block (`lastBlock < block.number`): `snap = slot0.tick`; `ema = snap + (ema − snap) · 2^(−Δt/H)`; write the slot. First ever touch: `ema = snap`.
- `2^(−Δt/H)` in fixed point; Δt >= 16·H gives 0 (EMA = snap).
- `anchorOf(PoolId) external view returns (int24 snapTick, int24 emaTick, bool fresh)`: if `lastBlock < block.number`, computes both from current `slot0` without writing; else returns stored. `fresh` = stored this block.
- `EMA_HALF_LIFE` = 60 s constant (V2-11 may change it with a DECISIONS entry).
- No maker logic yet: every swap on the v2 pool is pool-only until V2-07.

## Out of scope
Using the anchor in any check (V2-04, V2-06).

## Acceptance
- `test_V203_snapshotFixedWithinBlock`: a swap moves `slot0`; `anchorOf` unchanged until `vm.roll`.
- `test_V203_viewEqualsStored`: the lazy view before a block's first swap equals what that swap writes.
- `test_V203_emaHalfLife`: after H seconds at a new price the EMA covers half the gap, within 1 tick.
- `testFuzz_V203_emaBounded`: across random snapshots and warps, the EMA stays within [min snap, max snap].
- `test_V203_largeGapResets`: Δt >= 16·H sets EMA = snap.
- `test_V203_poolOnlyUntilV207`: the v2 pool's swaps equal an unhooked pool's.
- All v1 tests still pass.
