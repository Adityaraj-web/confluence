# Decisions

One entry per decision. Status is Decided, Open or Superseded. Open items must be decided before the feature that needs them starts. Add new entries at the bottom with the next number.

## D-01 Fork Ethereum mainnet at a pinned block
- Status: Decided (block number Open until kickoff)
- Why: official v4 PoolManager, official Aqua and the canonical AquaSwapVMRouter all live on mainnet; 1inch accepts local forks for its onchain-transfer requirement; a pinned block makes tests repeatable.
- Constraint: `FORK_BLOCK` must be after 25618917, the block the canonical router was deployed in.
- Block: `26349400`.

## D-02 The hook is the Aqua taker and pays by transfer
- Status: Decided, mechanism to verify in F02
- Why: SwapVM's taker trait `useTransferFromAndAquaPush` makes the router pull the taker's input and push it into the maker's Aqua balance, so the hook needs no taker callback. This avoids the riskiest callback-inside-unlock path.
- Verify against the swap-vm v1.0.2 source (the deployed router): which contract calls `transferFrom` on the taker, that the trait exists under that name, and that no rule requires the taker to be `tx.origin`. Priya's program must contain no `tx.origin`-based Controls guard.
- Still the top risk after D-13: Extruction does not change who the taker is. Ask mentors at hour 1.
- 1inch confirmed (Nov 5): a contract can be the taker, calling the router from inside another protocol's callback such as a v4 hook's beforeSwap. Still to verify in F02 from the v1.0.2 source: which address the router transferFroms, and any tx.origin or reentrancy restriction.

## D-03 Our router is AquaSwapVMRouter plus one instruction
- Status: **Superseded by D-13 (Nov 5)**
- Was: fork SwapVM, add a PoolPriceBand opcode, redeploy as ConfluenceRouter, ship Priya's strategy to it.

## D-04 SwapVM version
- Status: Decided (Nov 5)
- Choice: the `1inch/swap-vm` **v1.0.2** git tag, the source the deployed AquaSwapVMRouter was built from. Not `main`, whose refactored surface is not deployed.
- Consequence: `swap(order, tokenIn, tokenOut, amount, takerTraitsAndData)` (5 arguments); opcode indices come from `AquaOpcodes._opcodes()` at that tag.
- TS: `@1inch/swap-vm-sdk` 0.4.0 and `@1inch/aqua-sdk` 0.3.0, pinned exactly. They carry the canonical addresses. Do not take swap-vm-sdk 0.5.0 (released Nov 5, has breaking changes) unless an F-spec needs it and a DECISIONS entry says why.
- F00 records the exact tag or commit `forge install` resolved, and the aqua version swap-vm v1.0.2 depends on.
- 1inch confirmed (Nov 5): use the release, it is the audited version; main is experimental.
- F00 resolved (Nov 5), installed as submodules in `contracts/lib/`: swap-vm `v1.0.2` = `32c687c2b73101fc26549e48fa1ff8a4d73afbac`; aqua `0.1.0` = `b51f3b6e3c02fa5208e1429f0f14706b025d9dd6` (the version swap-vm's package.json depends on); solidity-utils `6.9.7`, OpenZeppelin `v5.4.0`, forge-std `v1.11.0` (all as swap-vm's package.json pins); v4-core `v4.0.0` = `e50237c43811bd9b526eff40f26772152a42daba`; v4-periphery `main` = `c6e4754dab11bd38c6f08ac51c3c868569e93d64`.
- swap-vm v1.0.2 builds with `via_ir = true`, solc 0.8.30. We use the same in the default profile (`evm_version = cancun` for v4); v4 and swap-vm compile together under one remapping set. No vendoring was needed.
- Note for F03: swap-vm has two interfaces in `src/instructions/Extruction.sol`: non-view `IExtruction.extruction` (swap) and `IStaticExtruction` (quote). One `view` function with the same signature satisfies both.

## D-05 Phase 1 takes the Aqua amount as a hint
- Status: Decided
- Why: the off-chain quoter can find the best split by simulation; it gets a working demo by hour 8. On-chain search is F12 (stretch).

## D-06 Aqua can never break a swap
- Status: Decided
- Why: makes the hook safe to attach to any pool. Any Aqua failure unwinds and the pool fills everything.

## D-07 The band checks execution price against pool spot price
- Status: Decided
- Why: protects Priya from fills at a stale price. Runs after the curve so the registers hold computed amounts. Since D-13 it runs as an Extruction step, not an opcode.

## D-08 Exact-input swaps only in phase 1
- Status: Decided
- Why: halves the delta cases to test. Exact-output swaps go pool-only.

## D-09 One registered maker order per pool
- Status: Decided
- Why: enough for the demo; multi-maker routing is out of scope.

## D-10 No claim that Priya's balance quotes on 1inch
- Status: Decided
- Why: unverified, and a fork demo cannot show aggregator routing. D-13 makes it more plausible (her strategy now sits on the canonical router) but still unproven.

## D-11 Opcode slot for PoolPriceBand
- Status: **Closed, not needed (Nov 5)**
- Why: D-13 removes the custom opcode. We use the existing Extruction opcode (index 32 on the canonical router per 1inch docs; F03 confirms the index in `AquaOpcodes._opcodes()`).

## D-12 Time gates
- Status: Decided
- Hour 1 mentor question; hour 8 F05 or F05-ALT; hour 12 team decision on switching projects.

## D-13 Use the canonical AquaSwapVMRouter; the band is an Extruction target
- Status: Decided (Nov 5, on 1inch's recommendation at the event)
- Decision: no forked or redeployed SwapVM. Priya ships her strategy with `app` = the deployed `AquaSwapVMRouter` v1.0.2 (`0x111111338c5091e8440b67b168bae16a668ac0de`). The band check is `PoolPriceBandExtruction`, an external contract that her program calls through the Extruction opcode (1inch's "Path C").
- Why: 1inch recommended it. It removes our riskiest Aqua-side work (fork, opcode table, version drift, redeploy). It meets "official Aqua/SwapVM contracts" fully. It also makes the band a reusable module any maker can attach to any strategy with no redeploy.
- Rules from 1inch's Extruction docs: the target must be non-upgradeable, and `quote()` and `swap()` must return identical amounts. We meet both with one stateless `view` function.
- Consequences: ConfluenceRouter is deleted from the plan. F03 shrinks to one contract and its tests. D-03 superseded, D-11 closed.
- 1inch confirmed (Nov 5): projects must use the official contracts, not their own swap-vm implementation.

## D-14 The band reads live pool state; quote/swap consistency holds within one transaction
- Status: Decided (Nov 5)
- Issue: 1inch lists block-state reads as a source of quote/swap mismatch. Our target reads `slot0`.
- Why it is safe for our path: inside `beforeSwap` the pool curve has not run yet, so `slot0` is the same for the hook's quote and its swap. F03 tests `quote == swap` in one transaction.
- Limitation, stated in the README: an outside taker who quotes in one block and swaps in a later one may find the quote stale if the pool price moved. Their swap then reverts or fills at the newly checked price. It is never filled outside the band.
