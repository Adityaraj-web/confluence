# CONFLUENCE: project guide for Claude Code

CONFLUENCE is a Uniswap v4 hook that blends a native pool with makers' 1inch Aqua strategies inside one swap.
v1 was built at ETHGlobal Mumbai (Nov 5-7, 2026) by Adityaraj Paul and Ayush Bhowmick (tag `v1-hackathon`).
v2 is a solo continuation by Adityaraj. **Current work: Phase 1 (protocol), specs V2-00 to V2-12.**

## v2 in seven steps (one swap)
1. Any caller swaps on the pool with empty `hookData`; the PoolManager calls `beforeSwap`.
2. First swap of the block: the hook records the block-start snapshot (`slot0` tick) and updates the EMA.
3. The hook builds venues: up to 8 pool tick ranges, and each registered maker's reserves and cap.
4. `SplitMath` solves the best split in closed form (exact in or exact out); dust legs dropped; at most 3 maker legs.
5. Per maker leg: take input from the PoolManager, call 1inch's `AquaSwapVMRouter.swap` as taker inside try/catch. The maker's program ends with `BandGuardV2`, which checks the fill against the hook's anchor.
6. The hook settles the output and returns one `BeforeSwapDelta`; one `ConfluenceSwap` event.
7. The pool curve fills the rest; the PoolManager nets every balance to zero.

## Specs at a glance (details in docs/specs/V2-*.md)
- M1 maths core: V2-00 reference model (gate G0) · V2-01 SplitMath · V2-02 PoolVenue
- M2 guard: V2-03 Anchor · V2-04 BandGuardV2
- M3 maker market: V2-05 StrategyTemplate + registry · V2-06 MakerVenue · V2-07 hint-free split (the core claim)
- M4 completeness: V2-08 exact output · V2-09 quoting parity + Lens
- M5 proof: V2-10 attack suite · V2-11 gas budget · V2-12 invariants + Phase 1 exit
- Order, status: `docs/FEATURES.md`. The v1 features F00-F12 are history; do not edit their specs.

## Definition of done (every spec)
- [ ] Acceptance tests pass; output shown
- [ ] All earlier tests still pass (v1 tests until V2-12 retires them with a DECISIONS entry)
- [ ] No new compiler warnings in our files
- [ ] FEATURES.md status updated; PROGRESS.md entry added
- [ ] DECISIONS.md entry for any choice the spec left open or any [VERIFY] answered
- [ ] Committed on the spec branch with `V2-xx:` messages; merged to `main` with `--no-ff`

## How we work (read first)
- ONE spec at a time from `docs/specs/V2-*.md`. Before coding: read the spec, the `docs/ARCHITECTURE-v2.md` sections it names, and the last five PROGRESS entries. Propose a plan in plan mode and wait for approval.
- Write the acceptance tests first and show them red, then make them green.
- A spec is done only when every check under **Acceptance** passes and the command output is shown.
- A design change gets one DECISIONS entry (decision, why, date). Never silently change an interface a spec defines.
- If a spec is wrong or impossible, stop and say so with evidence. No workarounds outside its scope.
- Edit only the files the spec lists. Ask before touching others.
- Small commits after each passing step. Never squash.
- Branches: `v2/<nn>-<name>` from `main`.

## Gates
- **G0 (V2-00, first test):** an ungated T1-shaped program fills through Unichain's router with a contract as taker. If not, stop and discuss.
- **M3 (end of V2-07):** a swap with empty `hookData` gives at least v1's hinted best (991549823315669231761 wei MUMB for 1,000 USDC).
- When working on a gated spec, say how the work affects the gate.

## Glossary
- **Venue**: anything the hook can buy from: one pool tick range, or one maker strategy.
- **Leg**: one maker's share of a swap, executed as one router call. The pool's share is not a leg.
- **Maker**: holds tokens in their own wallet and ships a SwapVM strategy to Aqua; tokens move only on a fill. (Priya in v1.)
- **Template T1**: the only strategy shape the hook prices: optional salt, flat fee, XYC curve, BandGuardV2.
- **Snapshot**: pool tick at the block's first `beforeSwap`; constant for the rest of the block.
- **EMA**: time-weighted average of snapshots in tick space, half-life `EMA_HALF_LIFE`.
- **Anchor**: (snapshot, EMA), read with `anchorOf(poolId)`.
- **Band**: a fill's execution price must be within `bandBps` of the snapshot price.
- **Drift**: `|snapshot − EMA|`; above the maker's `driftBps` the maker pauses.
- **Exclusive**: strategy flag; only the hook may be the taker.
- **Cap**: the most a venue can fill now (band, wallet, allowance, PoolManager balance).
- **Canonical router**: 1inch's deployed `AquaSwapVMRouter` v1.0.2. Never forked, modified or redeployed.
- **MUMB**: mock long-tail ERC-20 (18 decimals). Test pair MUMB/USDC.

## Repo layout
```
contracts/
  src/ConfluenceHook.sol
  src/BandGuardV2.sol                  v2 Extruction target
  src/ConfluenceLens.sol               v2 view contract
  src/libraries/                       SplitMath, PoolVenue, MakerVenue, AnchorLib, StrategyTemplate
  src/v1/                              v1 hook and band contract, frozen (moved in V2-00) for v1 tests and the attack suite
  test/base/                           ForkBase, StrategyLib, Vectors, ForkOracle
  test/unit/ test/fork/ test/attack/ test/gas/ test/invariant/
  test/vectors/                        JSON generated by reference/
reference/                 Python reference model (stdlib only)
scripts/                   TypeScript (strategy builder, demo runner)
web/                       v1 replay app (frozen until Phase 3)
docs/                      ARCHITECTURE-v2.md, specs/V2-*.md, DECISIONS, PROGRESS, FEATURES, THREATS, GAS
```

## Commands
- From `contracts/`: `forge build`, `forge test -vvv`, `forge test --match-test <name> -vvv`, `forge snapshot`
- Reference model (repo root): `python3 -m unittest reference/test_reference.py`; regenerate vectors: `python3 reference/gen_vectors.py` (output must be byte-identical on rerun)
- Fork tests read `MAINNET_RPC_URL`, `FORK_BLOCK`, `UNICHAIN_RPC_URL`, `UNICHAIN_FORK_BLOCK` from the root `.env`.
- Local chain: `set -a; source .env; set +a; anvil --fork-url $MAINNET_RPC_URL --fork-block-number $FORK_BLOCK`
- Scripts: `pnpm --dir scripts <script>`; typecheck `pnpm --dir scripts tsc --noEmit`

## Pinned facts (change only with a DECISIONS entry)
- Test chain: anvil fork of Ethereum mainnet at `FORK_BLOCK` 26349400 (D-01). Unichain (130) fork for gate G0 and V2-05.
- Aqua registry: `0x1111113ccf1426a8e30e2bff5e005d929bf6a90a`. AquaSwapVMRouter v1.0.2: `0x111111338c5091e8440b67b168bae16a668ac0de` (mainnet; Unichain address [VERIFY] in G0).
- SwapVM source: `1inch/swap-vm` tag **v1.0.2** (D-04). Opcodes on the router: Controls, XYCSwap, XYCConcentrate, Decay, Fee, PeggedSwap, Extruction. Indices from `AquaOpcodes._opcodes()`, never from docs.
- Uniswap v4 PoolManager: `0x000000000004444c5dc75cB358380D2e3dE08A90`. USDC: `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`.
- Solidity 0.8.30. TS SDKs `@1inch/swap-vm-sdk` 0.4.0, `@1inch/aqua-sdk` 0.3.0, exact.
- SwapVM sorts tokenA < tokenB; v4 sorts currency0 < currency1. They line up.
- v1 reference numbers (D-21): 1,000 USDC pool-only 984934194542570551127 wei MUMB; hinted best (hint 550000000) 991549823315669231761 wei.
- Proposed constants (ARCHITECTURE-v2 section 5) are fixed only by V2-11.

## Hard rules
- IMPORTANT: Aqua can never make a v4 swap fail. Every router call is inside try/catch; any failure settles back and the pool fills that share.
- The hook holds zero tokens after every swap. Tests assert it.
- The PoolManager must net to zero. Never fix a delta error by sending extra tokens.
- A swap's result is never worse than the pool alone from the same state, minus rounding. Tests assert it.
- `hookData` is ignored. The hook needs no off-chain input.
- The hook is immutable and ownerless: no owner, no admin, no proxy, no fee switch, no pause.
- We deploy no SwapVM or Aqua code. Custom logic goes only in `BandGuardV2`.
- `BandGuardV2` is stateless and non-upgradeable: no storage, no owner, one `view` `extruction` for quote and swap; it never writes swap amounts, only checks and reverts. Its parameters come from the strategy bytes.
- The guard reads the anchor (snapshot + EMA), never spot `slot0`.
- Every loop is bounded by a named constant.
- Keys: only anvil's public test keys, only in `.env` / `.env.example`. No paid APIs, no keys in code.
- Never claim a maker's balance "also quotes on 1inch". Unverified; stays out of code, docs and UI.
- No README, blog or sponsor-facing text unless a spec asks for it.

## Testing conventions
- Test names `test_V2xx_<behaviour>` / `testFuzz_V2xx_<behaviour>`.
- Fork tests extend `ForkBase`. Fund with `deal`, never whales.
- Assert exact balances: trader, each maker's wallet, each maker's Aqua virtual balance, the hook, the PoolManager.
- Compare against V2-00 vectors or `ForkOracle`, not hand-typed numbers.
- Compare split vs pool-only from one `vm.snapshotState()`.
- When a test fails, fix the cause. Never loosen an assertion or skip a test without asking.

## Where to look
- v2 design: `docs/ARCHITECTURE-v2.md`. v1 design: `docs/ARCHITECTURE.md`.
- Why things are as they are: `docs/DECISIONS.md` (D-27 onward is v2).
- Handoff log: `docs/PROGRESS.md`. Loop and prompts: `docs/WORKFLOW.md`.
- Extruction interface and registers: `src/instructions/Extruction.sol`, `src/libs/VM.sol` in swap-vm v1.0.2 under `contracts/lib/`.
- v4 state reads: `StateLibrary`, `TickBitmap`, `SqrtPriceMath`, `ProtocolFeeLibrary` under `contracts/lib/v4-core`.

## When unsure
- Read the source in `contracts/lib/` before guessing an API. Quote the file and line.
- Specs mark unverified facts [VERIFY]. Verify, then record the answer in DECISIONS.
- Ask one specific question instead of guessing.
- Review against the spec with the `spec-reviewer` subagent.

## Session start checklist
1. Read the last five PROGRESS entries.
2. Read the target spec and the Acceptance sections of its Depends-on specs.
3. Run `forge build` and the full test suite; report anything red before starting.
4. State the plan in plan mode and wait for approval.

## What we say (keep code and docs consistent with it)
- "A Uniswap v4 pool that blends its own liquidity with makers' 1inch Aqua strategies in one swap, priced on-chain, never worse than the pool alone."
- "Makers carry their own guard: fills are pinned to a block-start price no single transaction can move."

## Compaction
When compacting, keep: current spec ID, files changed, failing test names, the last command run, and the next step.
