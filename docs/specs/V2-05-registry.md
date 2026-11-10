# V2-05 StrategyTemplate and MakerRegistry

- Owner: Adityaraj
- Depends on: V2-04
- Branch: `v2/05-registry`
- Architecture: ARCHITECTURE-v2 sections 1, 5
- Decisions: D-09, D-18 (both superseded here); add one for the eviction rule

## Goal
Many makers per pool, each strategy verified to be a shape the hook can price exactly, with no way for one maker to remove another.

## Files
- `contracts/src/libraries/StrategyTemplate.sol`
- `contracts/src/ConfluenceHook.sol` (registry storage, `register`, `unregister`, `evict`)
- `scripts/src/strategy.ts` (template T1 built with `@1inch/swap-vm-sdk` 0.4.0)
- `contracts/test/fork/V205Registry.t.sol`

## Behaviour
- Template T1, in order: optional `_salt`, `_flatFeeAmountInXD(feeE9)`, `_xycSwapXD`, `_extruction(BandGuardV2, args)`. Opcode indices from `AquaOpcodes._opcodes()`, never typed in. No KYC opcode.
- `register(PoolKey key, Params p)` where `Params { uint32 feeE9; uint16 bandBps; uint16 driftBps; bool exclusive; bytes32 salt; }`, `msg.sender` is the maker. The hook rebuilds the order (maker, program), hashes it, and requires Aqua to report it shipped by the maker with the canonical router as app, 2 tokens, not docked (`rawBalances`).
- Storage per slot: maker, params, strategy hash. Order bytes rebuilt in memory at swap time.
- One strategy per maker per pool. `MAX_STRATEGIES` = 6. When full, a newcomer's real depth must exceed the smallest slot's; that slot is evicted. Real depth = min(virtual output-side balance, wallet balance, allowance to Aqua), both sides valued at the snapshot price.
- `unregister(key)`: maker only. `evict(key, maker)`: anyone, only if the strategy is docked or real depth is zero.
- Events: `MakerRegistered`, `MakerUnregistered`, `MakerEvicted(reason)`.

## Out of scope
Using registered makers in swaps (V2-06, V2-07).

## Acceptance
- `test_V205_templateFillsOnUnichain`: a real T1 strategy (with BandGuardV2) fills on the Unichain fork with the hook's address as taker (extends gate G0).
- `test_V205_templateMatchesSdk`: Solidity bytes equal SDK bytes for 3 parameter sets (fixture JSON written by `strategy.ts`).
- `test_V205_rejectsUnshipped`, `test_V205_rejectsForeignProgram`, `test_V205_rejectsDocked`.
- `test_V205_slotsAndEviction`, `test_V205_phantomDepthCannotEvict`, `test_V205_anyoneEvictsDocked`.
- `test_V205_noDisplacement`: maker B cannot remove maker A's slot (closes D-18).
