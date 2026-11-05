# CONFLUENCE: project guide for Claude Code

CONFLUENCE is a Uniswap v4 hook whose pool depth comes from a maker's 1inch Aqua strategy, not from locked liquidity.
Built at ETHGlobal Mumbai (Nov 5-7, 2026), Classic track, team of two, zero cost.
Target prizes: Uniswap "Build with Uniswap" and 1inch "Build an Aqua App".

## The mechanism in six steps (one exact-input swap)
1. The trader swaps through the v4 pool; the PoolManager calls our hook's `beforeSwap`.
2. The hook picks the Aqua slice: from the hint in `hookData` (phase 1) or its own bounded search (phase 2).
3. The hook takes that much input token out of the PoolManager.
4. The hook calls 1inch's deployed `AquaSwapVMRouter` `swap` as taker with `useTransferFromAndAquaPush`. Priya's program runs; its Extruction step calls our `PoolPriceBandExtruction`, which reverts if the fill is outside the band around the pool's live price. Aqua pulls MUMB from Priya to the hook and the router collects the hook's input into Priya's strategy.
5. The hook settles the MUMB into the PoolManager and returns a `BeforeSwapDelta` for what it served.
6. The pool curve fills the rest; the PoolManager checks every balance nets to zero or reverts everything.

## Features at a glance (details in docs/specs/)
- F00 scaffold · F01 fork test base · F02 Aqua baseline swap on the canonical router · F03 PoolPriceBand extruction
- F04 pool, seed and hook skeleton · F05 Aqua leg in the hook (hour-8 gate) · F05-ALT router-level split
- F06 safety fallbacks · F07 off-chain quoter · F08 invariants and fuzzing
- F09 setup and demo scripts · F10 demo web app · F11 submission pack · F12 on-chain search (stretch)

## Definition of done (every feature)
- [ ] Acceptance tests pass; output shown
- [ ] No new compiler warnings in our files
- [ ] FEATURES.md status updated; PROGRESS.md entry added
- [ ] DECISIONS.md entry for any choice the spec left open
- [ ] Committed on the feature branch with `F0X:` messages

## How we work (read first)
- We build ONE feature at a time from `docs/specs/`. Order, owner and status live in `docs/FEATURES.md`.
- Before coding: read the feature's spec and the `docs/ARCHITECTURE.md` sections it names. Propose a plan and wait for approval.
- A feature is done only when every check under its **Acceptance** heading passes and you have shown the command output.
- After a feature: set its status in `docs/FEATURES.md` and append an entry to `docs/PROGRESS.md`.
- A design change gets one entry in `docs/DECISIONS.md` (decision, why, date). Never silently change an interface a spec defines.
- If a spec is wrong or impossible, stop and say so with evidence. Do not invent a workaround outside its scope.
- Edit only the files the spec lists. Ask before touching another feature's files.
- Commit after each passing step: `F0X: <what changed>`. Small commits, never squash (1inch checks commit history).

## Team and branches
- T1 owns the v4 side: pool, hook, safety, invariants. T2 owns the Aqua side: extruction, strategy, quoter.
- Branches `t1/<feature>` and `t2/<feature>`; merge to `main` when the feature's acceptance passes.
- `docs/PROGRESS.md` is how the two of us hand off. Read its last five entries at session start.

## Time gates (hours after kickoff)
- Hour 1: ask 1inch and Uniswap mentors whether a hook can be the Aqua taker on the canonical router inside `beforeSwap`.
- Hour 8: `test_F05_fullAquaFill` passes, or we switch to F05-ALT (router-level split).
- Hour 12: if neither path moves real tokens on the fork, the team decides whether to switch projects.
- When working on a gated feature, say how it affects the gate.

## Glossary
- **Priya / maker**: holds MUMB, ships a SwapVM strategy to Aqua; her tokens stay in her wallet until a fill.
- **Trader / taker**: swaps through the v4 pool. Inside the hook, the hook itself is Aqua's taker.
- **Canonical router**: 1inch's deployed `AquaSwapVMRouter` v1.0.2. We never fork, modify or redeploy it.
- **Extruction**: the SwapVM opcode that calls a maker-chosen external contract and takes back updated swap registers. It is how we add custom logic without a custom opcode (D-13).
- **PoolPriceBandExtruction**: our Extruction target. A stateless, non-upgradeable contract with one `view` function.
- **Aqua leg**: the part of a swap filled from Priya's strategy inside the hook.
- **Pool leg**: the rest, filled by the pool's own curve against the seed position.
- **Hint**: the Aqua input amount passed in `hookData` (phase 1, chosen off-chain by the quoter).
- **Band**: Aqua refuses to fill outside +/- `bandBps` of the pool's live price.
- **MUMB**: our mock long-tail ERC-20 (18 decimals). The pair is MUMB/USDC.

## Repo layout
```
contracts/                 Foundry project (created in F00)
  src/ConfluenceHook.sol
  src/PoolPriceBandExtruction.sol      Extruction target (band check)
  src/mocks/MockMUMB.sol
  test/base/ForkBase.t.sol             shared fork setup (F01)
  test/base/StrategyLib.sol            builds Priya's program and order (F02, F03)
  test/unit/  test/fork/  test/invariant/
  script/                              forge deploy and setup scripts
scripts/                   TypeScript: ship strategy, quoter, demo runner
web/                       Vite + React demo app
docs/                      specs and context
```

## Commands
- Build and test (from `contracts/`): `forge build`, `forge test -vvv`
- One test: `forge test --match-test <name> -vvv`
- Fork tests read `MAINNET_RPC_URL` and `FORK_BLOCK` from `.env`.
- Local chain: `anvil --fork-url $MAINNET_RPC_URL --fork-block-number $FORK_BLOCK`
- Scripts: `pnpm --dir scripts <script>`; web app: `pnpm --dir web dev`
- If F00 sets up different commands, update this section in the same commit.

## Pinned facts (change only with a DECISIONS entry)
- Chain: local anvil fork of Ethereum mainnet at `FORK_BLOCK` (chosen at kickoff, recorded as D-01).
- Official Aqua registry: `0x1111113ccf1426a8e30e2bff5e005d929bf6a90a`. Use as deployed; never modify or redeploy.
- Official SwapVM router, `AquaSwapVMRouter` v1.0.2: `0x111111338c5091e8440b67b168bae16a668ac0de`. We USE this one; Priya ships with it as the Aqua `app`. Never modify or redeploy.
- SwapVM source: the `1inch/swap-vm` **v1.0.2** git tag, the source of the deployed router (D-04). Not `main`; its opcode numbers and `swap` signature differ.
- Opcode set on the canonical router: Controls, XYCSwap, XYCConcentrate, Decay, Fee, PeggedSwap, Extruction. Programs may use only these. Read opcode indices from `AquaOpcodes._opcodes()` in `contracts/lib/`; never hard-code them from docs.
- Uniswap v4 PoolManager: `0x000000000004444c5dc75cB358380D2e3dE08A90`.
- USDC: `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` (6 decimals).
- Solidity 0.8.30.
- SwapVM sorts tokenA < tokenB by address; v4 sorts currency0 < currency1 by address. They line up.
- TS SDKs: `@1inch/swap-vm-sdk` 0.4.0 and `@1inch/aqua-sdk` 0.3.0, exact versions (D-04).

## Hard rules
- IMPORTANT: Aqua can never make a v4 swap fail. Every Aqua call in the hook is wrapped in try/catch; on failure the pool fills the whole swap.
- The hook holds zero tokens after every swap. Tests assert this.
- The PoolManager must net to zero. Never fix a delta error by sending extra tokens.
- Phase 1 handles exact-input swaps only; exact-output swaps go pool-only.
- We deploy no SwapVM or Aqua code. Custom logic goes only in our Extruction target.
- `PoolPriceBandExtruction` is stateless and non-upgradeable: no storage, no owner, no proxy, one `view` `extruction` function serving both quote and swap. It never writes swap amounts; it only checks and reverts. Its parameters come from the strategy bytes.
- Priya's program puts the Extruction step after the curve, so the registers hold computed amounts when the band checks them.
- Keys: only anvil's public test keys, only in `.env` / `.env.example`. No paid APIs, no API keys in code.
- Never claim that Priya's balance "also quotes on 1inch". It is unverified and stays out of code, docs and UI.
- Do not write README, FEEDBACK.md or other sponsor-facing text unless the current spec asks for it.

## Testing conventions
- Every feature adds tests named `test_F0X_<behaviour>`.
- Fork tests extend `ForkBase` (F01). Fund accounts with `deal`, never with whales.
- Assert balances explicitly: trader, Priya's wallet, Priya's Aqua virtual balance, the hook, the PoolManager.
- When a test fails, fix the cause. Do not loosen an assertion or skip a test without asking.
- Use anvil snapshots (`vm.snapshot` / `vm.revertTo`) to compare pool-only and split fills from one state.

## Where to look
- Components, swap flow, token flow, interfaces: `docs/ARCHITECTURE.md`
- Feature list, owners, gates: `docs/FEATURES.md`
- Why things are the way they are: `docs/DECISIONS.md`
- Prize requirements checklist: `docs/PRIZES.md`
- Demo script: `docs/DEMO.md`
- Session log and handoff: `docs/PROGRESS.md`
- Our working loop and prompts: `docs/WORKFLOW.md`
- Path rules for Solidity, scripts and web load from `.claude/rules/`.
- Extruction interface and register types: `src/instructions/Extruction.sol` and `src/libs/VM.sol` in the swap-vm v1.0.2 source under `contracts/lib/`.

## When unsure
- Read the source in `contracts/lib/` before guessing an API. Quote the file and line you relied on.
- Specs mark unverified facts [VERIFY]. Verify before building on them and record the answer in DECISIONS.
- Ask one specific question instead of guessing.
- For a review against the spec, use the `spec-reviewer` subagent.

## Session start checklist
1. Read the last five entries of `docs/PROGRESS.md`.
2. Read the target spec and its Depends-on specs' Acceptance sections.
3. Run `forge build` and the previous feature's tests; report anything red before starting.
4. State the plan in plan mode and wait for approval.

## What we say in the pitch (keep code and UI consistent with it)
- "A v4 pool with almost no locked liquidity that trades deep, because its depth sits in makers' own wallets via Aqua."
- "A SwapVM Extruction module, running on 1inch's own deployed router, pins Aqua fills to the pool's live price. Any maker can plug it into any strategy with no redeploy."

## Compaction
When compacting, keep: current feature ID, files changed, failing test names, the last command run, and the next step.
