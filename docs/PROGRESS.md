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

## 2026-11-06 11:05 IST · F03 · T2 · Done
- Changed: contracts/src/PoolPriceBandExtruction.sol, contracts/test/unit/F03PoolPriceBand.t.sol, contracts/test/fork/F03BandOnFork.t.sol, contracts/test/base/StrategyLib.sol (`_buildBandProgram`; `_buildProgram` unchanged), docs (ARCHITECTURE, DECISIONS, FEATURES, PROGRESS).
- Verified: `forge test --match-test test_F03 -vvv` -> 18 passed (9 acceptance, 9 extra); `forge test` -> 28 passed; no warnings in our files. 12 deliberately injected contract bugs, run against the unit tests on a scratch copy, each failed at least one test. `spec-reviewer` ran before the implementation existed, against its own reference contract; its 3 coverage gaps are closed. It has not reviewed the final contract.
- Decisions: D-16 added (`InvalidArgsLength`, `InvalidBand` in `build`, the [VERIFY] answers).
- Next: F04 (T1), then F05 (both). F05's `ConfluenceBase` uses `band.build(manager, key, bandBps)` and `_buildBandProgram(feeE9, address(band), args)`. Hour-8 gate: F03 is one of F05's two dependencies, and running the router inside `beforeSwap` is still unproven until `test_F05_fullAquaFill`.
- Open issues: (1) Repeat fills: a second 1,000 USDC fill in the same direction is about 2.9% off at a 200 bps band and is refused unless the pool moves, so F07 and F08 must expect it. (2) The band follows `slot0`, so on a thin pool someone can cheaply push the price towards Priya's stale curve and then fill her; discuss before the pitch claims stale-price protection. (3) ARCHITECTURE section 3 step 9 keeps its [VERIFY] tag, which belongs to F04.

## 2026-11-06 11:19 IST · F03 · T2 · Done
- Changed: docs/PROGRESS.md only. F03 sign-off; FEATURES already shows Done.
- Verified: `forge test --match-test test_F03 -vvv` -> 18 passed, 0 failed (10 unit, 8 fork).
- Decisions: none. The team chose not to re-run `spec-reviewer` on the final contract, relying on the bug-injection run, and agreed that the step 9 [VERIFY] tag stays for F04.
- Next: merge `t2/f03-pool-price-band` to `main`, then F04 (T1) and F05 (both).
- Open issues: the repeat-fill refusal and thin-pool `slot0` points from the previous entry still stand.

## 2026-11-06 · F04 · T1 · Done
- Changed: contracts/src/ConfluenceHook.sol, contracts/test/base/PoolBase.t.sol, contracts/test/fork/F04PoolSkeleton.t.sol, docs (DECISIONS, FEATURES, ARCHITECTURE step 9, F04 spec's BaseHook line).
- Verified: `forge test --match-path test/fork/F04PoolSkeleton.t.sol -vvv` -> 11 passed (4 acceptance: hookPermissions, poolOnlySwap, registerOrderMakerOnly, exactOutputStillWorks; 7 extra); `forge test` -> 39 passed (28 earlier + 11); `forge build --force` shows no warnings in our files. Tests were committed red first (3 pass, 8 fail at the stub), then green. `spec-reviewer` found every Behaviour and Acceptance line met; its one weak-test point (nothing proved `beforeSwap` runs) is closed with `vm.expectCall` in `test_F04_poolOnlySwap`. 1,000 USDC buys 984.934194542570551127 MUMB pool-only.
- Decisions: D-17 (no `BaseHook` in lib/v4-periphery, so the hook implements `IHooks` directly; `BeforeSwapDelta` is `(+a, -b)` for exact input, cited), D-18 (events, errors, anchor price maths, seed range).
- Next: F05 (both). Hour-8 gate: F04 is now done, so `test_F05_fullAquaFill` is the open item, and running the router inside `beforeSwap` is still unproven. `PoolBase` gives F05 the hook, pool, seed and `_swapExactIn(who, zeroForOne, amountIn, hookData)`. F05's hook needs `ConfluenceHook` extended in place, so it will touch the F04 files.
- Open issues: (1) The `(+a, -b)` sign is confirmed from v4's full-fill custom-curve hook, not yet by a partial fill; F05 proves it. (2) `registerOrder` lets any maker displace another maker's order for the pool (D-18); it can only switch off the Aqua leg. (3) A 1,000 USDC pool-only buy moves the pool price about 2.4%, more than a 200 bps band, so F05 to F08 should expect that. (4) Exact amounts in the F04 tests assume USDC is currency0 at this `FORK_BLOCK` and deployer nonce; a change to either breaks them loudly.

## 2026-11-06 08:10 UTC · F05 · T1 + T2 · Done
- Changed: contracts/src/ConfluenceHook.sol, contracts/test/base/ConfluenceBase.t.sol, contracts/test/fork/F05AquaLeg.t.sol, docs (DECISIONS, FEATURES, ARCHITECTURE step 9).
- Verified: `forge test --match-path test/fork/F05AquaLeg.t.sol -vvv` -> 10 passed (5 acceptance: fullAquaFill, partialSplit, splitBeatsPoolOnly, reverseDirection, zeroHintIsPoolOnly; 5 extra: skipBadHintLength, skipHintAboveAmount, skipExactOutput, skipNoOrder, approvalReset); `forge test` -> 49 passed (39 earlier + 10); `forge build --force` shows no new warnings in our files (the swap-vm `ProgramBuilder` warning and F04's constructor `missing-zero-check` remain). Tests were committed red first (4 failed at the stub), then green. Measured MUMB out for 1,000 USDC: pool-only 984.934194542570551127; 100% Aqua 987.158034397061298850; 60% split 991.498196999760649578 (Aqua leg 594.642846492283162124 for 600 USDC + pool leg 396.855350507477487454 for 400 USDC).
- Decisions: D-19 (hour-8 gate met; source answers; settler, skip order, minimum out; no `AquaSkipped` until F06).
- Next: F06 (T1), then F07 (T2). Hour-8 gate: met, F05-ALT not needed. Hour 12: a path moves real tokens on the fork.
- Open issues: (1) A MUMB-input hint above the PoolManager's MUMB (the seed's 2,500e18) reverts the swap: F06 guard. (2) No try/catch: any router revert, band breach or lock re-entry reverts the whole swap until F06. (3) A hint above `int128` max reverts in `SafeCast`, also F06's. (4) `spec-reviewer` (Nov 6): every Behaviour and Acceptance line met, no blocking gaps; one deviation, the extra skip on `hookData` not 32 bytes (in NatSpec, D-19 and tested). Weak tests: `test_F05_approvalReset` checks only the allowance after the call, so "approve exactly `a`" is not pinned during the call; `splitBeatsPoolOnly` has no margin (other tests pin exact amounts). The approvalReset weakness was closed in f087db4 (exact `approve(router, a)` via `vm.expectCall`).
- Reviewed: T2 reviewed and approved (Ayush, Nov 6); 49 passed on his laptop.

## 2026-11-06 · F06 · T1 · Done
- Changed: contracts/src/ConfluenceHook.sol, contracts/test/fork/F06Safety.t.sol, docs (DECISIONS D-20 and D-18 amended, ARCHITECTURE sections 3, 6 and 7, FEATURES, PROGRESS).
- Verified: `forge test --match-path test/fork/F06Safety.t.sol -vv` -> 15 passed (5 acceptance: bandBreachFallsBack, dockedStrategyFallsBack, insufficientMakerBalanceFallsBack, makerRevokedApprovalFallsBack, unregisteredOrderIsPoolOnly; 10 extra); `forge test` -> 64 passed (49 earlier + 15); `forge build --force` exits 0 with no new warnings in our files (the swap-vm `ProgramBuilder` warning and F04's constructor `missing-zero-check` remain). Tests were committed red first (11 of 12 failed, each at the router revert propagating or the missing event), then green in steps. The gas cap test was red first too (the burning strategy cost 2,604,386 extra gas), then 726,414 with the cap. `spec-reviewer` (Nov 6): every Behaviour and Acceptance line met, no spec or hard-rule gaps; weak tests it found (the revoked-approval and wallet-short tests checked the selector only) now assert the exact revert bytes; uncovered paths are in D-20.
- Decisions: D-20 (skip-event policy and reasons, bounded revert data, the int128 reasoning, gas constants with measurements and method, accepted edge, warning for F07/F09/F10). D-18 amended: a registered strategy can burn gas, bounded by `MAX_AQUA_GAS`.
- Next: F07 (T2), then F08 (T1). Hour-8 gate: met earlier (F05). Hour 12: F05 already moves real tokens on the fork and F06 does not change that; the Gate log row is now filled in FEATURES (not triggered).
- **For F07, F09, F10:** the hook's behaviour depends on the transaction's gas limit. In this harness Aqua is skipped up to a limit of 396,525 and first fills at 458,286, so `eth_estimateGas` can land where Aqua is skipped. Set an explicit gas limit (for example 1,500,000) on the swap, simulate at the same limit, and read `AquaFill` / `AquaSkipped` from the receipt (D-20).
- Open issues: (1) For F08: `registerOrder` has no limit on `order.data`; a large order costs gas on every hinted swap before the gas check. Add a size limit and a test. (2) `AQUA_GAS_RESERVE` (150,000) was measured with v4-core's `PoolSwapTest` and a pool leg that crosses no tick; a real swap router or a pool leg crossing ticks needs more, and no test covers it. Re-measure with the router the demo uses (F09/F10). (3) Not covered: a router return shorter than 96 bytes, a failing `settle(b)` after a success, a router that leaves dust (D-20). (4) A gas-burning strategy still costs the trader up to about 726,000 gas more than a pool-only swap. T2's non-blocking notes: (5) = (2) sharpened: the reserve was measured only with `PoolSwapTest` and a pool leg that crosses no tick; re-measure for a heavier router or a tick-crossing pool leg (F08). (6) = the F07/F09/F10 warning above: each must set an explicit gas limit (for example 1,500,000) and read `AquaFill` / `AquaSkipped` from the receipt. (7) = (1): `order.data` is unbounded in `registerOrder` (F08).
- Reviewed: T2 reviewed and approved (Ayush, Nov 6); 64 passed on his laptop; no blocking problems.

## 2026-11-06 · F07 · T2 · Done
- Changed: scripts/src/quoter.ts, scripts/src/config.ts, scripts/src/abis/ (generator and generated PoolSwapTest, ConfluenceHook), scripts/test/quoter.test.ts, scripts/test/quoter.live.test.ts, scripts/package.json (`quote`, `test`, `test:int`, `abis`); pulled forward from F09: contracts/script/Setup.s.sol, contracts/foundry.toml (`fs_permissions`), deployments/.gitkeep; docs (DECISIONS D-21, FEATURES, PROGRESS).
- Verified: `forge build --force` clean (only the swap-vm `ProgramBuilder` and F04 `missing-zero-check` warnings); `forge test` 64 passed, 0 failed, run again after the F07 changes. `pnpm --dir scripts test` 17 passed; `pnpm --dir scripts test:int` 6 passed against anvil at `FORK_BLOCK` after `forge script script/Setup.s.sol --broadcast`; `tsc --noEmit` clean. `pnpm --dir scripts quote --amount 1000 --dir usdc-to-mumb`: pool-only 984.934194542570551127 MUMB, best split 991.549823315669231761 (hint 550000000, 55% to Aqua); 60% and 100% rows equal F05's measured values. `mumb-to-usdc` gives the same numbers in USDC. Tests were committed red first. `spec-reviewer`: every Behaviour and Acceptance line met, no rule breach; it did not run the live tests (shown above); weak tests it named are tightened (strict `>` in the reverse direction, a gas-limit live test), the unit hint-0 test stays weak by design (D-21).
- Decisions: D-21 (quoter choices, the setup pulled forward from F09, funding by `anvil_setStorageAt`, the swap router, the `.env` note).
- Next: F09 (T2) extends `Setup.s.sol` (step 8 snapshot), adds `shipStrategy.ts`, `demo.ts` and the Makefile; F08 (T1). Hour gates: not affected.
- Open issues: (1) This machine's `.env` lacks `DEPLOYER_PRIVATE_KEY`, `PRIYA_PRIVATE_KEY`, `TRADER_PRIVATE_KEY` (they are in `.env.example`); add them. (2) `realSwapMatchesQuote` compares one real swap with its quote; F09's demo runner must still read `AquaFill` / `AquaSkipped` from every receipt (the quoter cannot see logs). (3) D-20's gas reserve was measured with `PoolSwapTest`; another router in F10 means re-measuring. (4) `contracts/broadcast/` and `deployments/local.json` are now in `.gitignore` (`deployments/.gitkeep` stays). (5) A second fill in the same direction is subject to the band (F03).
- **Run F07 live from a clean clone** (repo root; `.env` needs `MAINNET_RPC_URL` for an archive node and `FORK_BLOCK`, as in `.env.example`; the three anvil keys are loaded from `.env.example`):
  ```
  git submodule update --init --recursive
  pnpm --dir scripts install --frozen-lockfile
  (cd contracts && forge build)

  # terminal 1: the fork (anvil does not read .env itself)
  set -a; source .env; set +a; anvil --fork-url $MAINNET_RPC_URL --fork-block-number $FORK_BLOCK

  # terminal 2: setup once per fresh anvil (writes deployments/local.json)
  set -a; source .env.example; source .env; set +a
  (cd contracts && forge script script/Setup.s.sol --rpc-url http://127.0.0.1:8545 --broadcast)

  pnpm --dir scripts quote --amount 1000 --dir usdc-to-mumb   # table; best split > pool only
  pnpm --dir scripts test                                      # 17 unit tests, no chain
  pnpm --dir scripts test:int                                  # 6 live tests (loads ../.env.example, then ../.env)
  pnpm --dir scripts tsc --noEmit
  ```
  `test:int` fails, not skips, without the anvil and the setup. `realSwapMatchesQuote` sends a real swap inside an `evm_snapshot` and reverts it, so the state is unchanged afterwards. `pnpm --dir scripts abis` regenerates the ABIs after a contract change.
