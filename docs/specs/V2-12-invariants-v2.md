# V2-12 Invariants v2 and Phase 1 exit

- Owner: Adityaraj
- Depends on: all V2 specs
- Branch: `v2/12-invariants`
- Architecture: all sections

## Goal
Stateful fuzzing of the whole market, and a clear finish line for Phase 1.

## Files
- `contracts/test/invariant/V2Invariants.t.sol`, `contracts/test/invariant/V2Handler.sol`
- `docs/ARCHITECTURE.md` (v2 merged in; ARCHITECTURE-v2.md deleted), `README.md` (v2 section, Ayush credited as co-builder of v1)

## Behaviour
- Handler actions: swaps (random size, type, direction); makers ship, dock, re-ship, spend from wallets, change allowances; register, unregister, evict; `vm.roll` and `vm.warp`; outside price shocks.
- Invariants: hook holds nothing; per-strategy maker value conserved through fills; no fill outside the band of that block's snapshot; no fill while drift is broken; Σlegs + pool = trade; anchor constant within a block; slots <= `MAX_STRATEGIES`; realised output >= pool-only from the same state, minus rounding.
- v1 invariant suite retired only after v2's covers its properties (DECISIONS entry).

## Acceptance
- Campaign passes at runs/depth agreed in DECISIONS with a fixed seed.
- `test_V212_handlerReachesAllPaths`: every status code and 0-3 legs occur.
- **Phase 1 exit:** every V2 test green; THREATS.md and GAS.md exist; DECISIONS current; ARCHITECTURE.md describes v2; tag `v2-phase1`.
