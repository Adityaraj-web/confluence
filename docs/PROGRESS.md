# Progress log

Newest entry at the bottom. Claude appends one entry after each feature step; humans may add notes too. Keep each entry short.

Entry format:

```
## <YYYY-MM-DD HH:MM IST> · <F0X> · <T1|T2> · <Done|In progress|Blocked>
- Changed: <files>
- Verified: <test command> -> <result>
- Decisions: <D-xx added or none>
- Next: <the next concrete step>
- Open issues: <none, or one line each>
```

## 2026-10-30 · pre-kickoff · both · Done
- Changed: docs drafted (CLAUDE.md, ARCHITECTURE, FEATURES, DECISIONS, PRIZES, DEMO, WORKFLOW, specs F00-F12).
- Verified: no code exists yet (Classic track rule).
- Decisions: D-04 and D-11 still Open.
- Next: at kickoff, create the repo, commit these docs, start F00.
- Open issues: FORK_BLOCK to fill in at kickoff. PoolManager address filled in on Oct 30.

## 2026-11-05 · pre-kickoff · both · Done
- Changed: CLAUDE.md, ARCHITECTURE, DECISIONS, FEATURES, PRIZES, DEMO, specs F00-F03, F05, F05-ALT, F11, .claude rules and spec-reviewer. 1inch recommended using their deployed SwapVM router with an Extruction instead of a custom opcode.
- Verified: canonical Aqua and router addresses and the Extruction interface checked against 1inch's docs (Nov 5).
- Decisions: D-13 and D-14 added; D-03 superseded; D-04 decided (v1.0.2); D-11 closed.
- Next: create the repo, commit these docs, fill D-01 FORK_BLOCK, start F00.
- Open issues: D-02 (hook as taker inside `beforeSwap`) is the hour-1 mentor question.

## 2026-11-05 · F00 · both · Done
- Changed: contracts/ (foundry.toml, remappings.txt, lib/ submodules, test/unit/Smoke.t.sol), .env.example, LICENSE, scripts/ (package.json, tsconfig, pnpm-workspace.yaml, src/index.ts), web/ (Vite react-ts), CLAUDE.md Commands.
- Verified: `forge build` ok, no warnings; `forge test --match-test test_F00_smoke` pass; `pnpm --dir scripts tsc --noEmit` ok; `pnpm --dir web build` ok; forge reads MAINNET_RPC_URL and FORK_BLOCK from the root .env when run in contracts/.
- Decisions: D-04 updated with resolved commits, via_ir note, Extruction/IStaticExtruction note.
- Next: F01 (fork test base, MockMUMB, T1) and F02 (T2).
- Open issues: none. RPC must be archive for block 26349400 (untested until F01).

## 2026-11-05 · F01 · T1 · Done
- Changed: contracts/src/mocks/MockMUMB.sol, contracts/test/base/ForkBase.t.sol, contracts/test/fork/F01ForkBase.t.sol.
- Verified: `forge test --match-path test/fork/F01ForkBase.t.sol -vvv` -> 5 passed (officialContractsExist, routerBoundToAqua, actorsFunded, sortedPair, mintOnlyDeployer); `forge test` -> 6 passed incl. F00 smoke; no warnings in our files. Router `AQUA()` equals the Aqua registry; `eip712Domain()` reports name "1inch SwapVM v1.0", version "1.0.2". RPC forks FORK_BLOCK fine (archive OK).
- Decisions: none.
- Next: F04 (T1, pool, seed position, hook skeleton); F02 (T2) can now extend ForkBase.
- Open issues: none.

## 2026-11-06 05:22 IST · F02 · T2 · Done
- Changed: contracts/test/fork/F02AquaBaseline.t.sol, contracts/test/base/StrategyLib.sol, contracts/test/base/TakerHelper.sol, docs (DECISIONS, FEATURES, PROGRESS).
- Verified: `forge test --match-path test/fork/F02AquaBaseline.t.sol -vvv` -> 4 passed (shipCreatesVirtualBalances, takerContractSwap, quoteMatchesSwap, noTxOriginRequirement) on the deployed router; `forge test` -> 10 passed. 1,000 USDC in fills 987.158034397061298850 MUMB. No warnings in our files; importing swap-vm's `ProgramBuilder` adds one warning located in that lib file.
- Decisions: D-02 and D-04 updated with the [VERIFY] answers; D-15 added. Takers approve the router, not Aqua. Flat-fee scale is 1e9 = 100%.
- Next: F03 (T2). Read D-15 first: the band sees the net-of-fee input, and ARCHITECTURE section 3 step 7 and section 5 need correcting there. Hour-8 gate: the token path from a contract taker works; running inside `beforeSwap` is still unproven until F05.
- Open issues: ARCHITECTURE still carries its [VERIFY in F02] tags; D-02 and D-04 hold the answers.

## 2026-11-06 06:43 IST · F03 · T2 · In progress
- Changed: contracts/src/PoolPriceBandExtruction.sol (skeleton, every function reverts), contracts/test/base/StrategyLib.sol (`_buildBandProgram`), contracts/test/unit/F03PoolPriceBand.t.sol, contracts/test/fork/F03BandOnFork.t.sol, docs/FEATURES.md.
- Verified: `forge test --match-test test_F03` -> 17 failed, as intended, all at the skeleton's revert; `forge test --no-match-test test_F03` -> 10 passed.
- Decisions: none recorded yet. Team approved `InvalidArgsLength`, `InvalidBand` in `build` as well as `parse`, and the ARCHITECTURE corrections; D-16 and the edits land when F03 is finished.
- Next: implement the contract, checking in this order: parse and band validity, token match, `getSlot0`, not-computed, price maths, band check.
- Open issues: the skeleton gives 4 temporary compiler warnings in our file; the implementation removes them.
