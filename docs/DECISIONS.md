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
- F02 verified (Nov 6), v1.0.2 source and a fork trace:
  - The router pulls the taker's input (`SwapVM.sol:235`), so the hook approves the **router**, not Aqua. The router approves Aqua and calls `push`, which forwards the tokens to the maker's wallet (`Aqua.sol:78`). Trait name confirmed: `useTransferFromAndAquaPush`, flag `0x0040` (`TakerTraits.sol:58,99`).
  - Output goes through `AQUA.pull`, which does `transferFrom(maker, to)` (`SwapVM.sol:286`, `Aqua.sol:68`), so the maker approves Aqua.
  - No `tx.origin` rule on the taker. The only `tx.origin` use is the opcode `_onlyTxOriginTokenBalanceNonZero` (`Controls.sol:125`); Priya's program must not include it.
  - Reentrancy: a transient lock per order hash (`SwapVM.sol:164`). It blocks only re-entry on the same order, and a revert clears it, so the hook's try/catch is unaffected.
  - Not covered by F02: running inside `beforeSwap`. `test_F02_takerContractSwap` proves the token path from a contract taker; F05 proves it inside the hook.

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
- F02 verified (Nov 6), v1.0.2 source and read-only calls to the deployed router at `FORK_BLOCK`:
  - `swap` and `quote` both take `(ISwapVM.Order order, address tokenIn, address tokenOut, uint256 amount, bytes takerTraitsAndData)` and return `(amountIn, amountOut, orderHash)` (`ISwapVM.sol:38-61`). `ISwapVM.quote` is `view`, so calling through the interface is a STATICCALL.
  - `takerTraitsAndData`: a 22-byte header (`uint160` of ten 16-bit slice end-offsets, then `uint16` flags), then `threshold(32 or 0) | to(20 or 0) | deadline(5 or 0) | hook data x4 | callback data x2 | instructionsArgs | signature` (`TakerTraits.sol:139-159`). Build it with `TakerTraitsLib.build`.
  - The strategy passed to `ship` is `abi.encode(order)`. `ship` hashes it with keccak256 (`Aqua.sol:41`), and the router's `hash` for Aqua orders is `keccak256(abi.encode(order))` (`SwapVM.sol:99`). The two match on the deployed router.
  - Runtime opcode indices: `_xycSwapXD` 17, `_salt` 20, `_flatFeeAmountInXD` 21, `_extruction` 32, `_onlyTxOriginTokenBalanceNonZero` 33; the table has 34 entries. `_opcodes()` overwrites array element 0 with the length (`AquaOpcodes.sol:79-83`), so runtime index = source position - 1. Code still looks indices up rather than hard-coding them.
  - The flat fee is `Fee._flatFeeAmountInXD`, scaled 1e9 = 100% (`Fee.sol:17`), so 0.30% is `3_000_000`. It runs the rest of the program inside itself (`Fee.sol:86-91`). See D-15 for what that means for F03.

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

## D-15 F02 test helper shape; the band sees the net-of-fee input
- Status: Decided (Nov 6) for the helpers; the band note is for F03 to act on
- `StrategyLib` is an `abstract contract` inheriting `AquaOpcodes`, despite its name. `_opcodes()` and the instruction pointers are internal, so a library cannot reach them. swap-vm's own `AquaStrategyBuilders` uses the same pattern with `AquaOpcodesDebug`; ours uses the non-debug table the router runs. It imports `ProgramBuilder` from `@1inch/swap-vm/test/utils/`, which emits one compiler warning located in that lib file (function-pointer comparison).
- `TakerHelper` follows the hook's flow: funded by `deal` where the hook would `take`, approves exactly `amountIn` to the router, receives the output itself (`to` = zero), resets the approval, then forwards the output where the hook would `settle`. `isFirstTransferFromTaker = false`, matching ARCHITECTURE section 3 step 7.
- For F03: with `fee, curve, Extruction`, the Extruction step runs inside the fee's nested `runLoop`, which runs to the end of the program, so no step can run after the fee returns. On exact input the registers hold `amountIn` net of the fee, so the band checks `(a - fee) / b`, not `a / b`. ARCHITECTURE section 3 step 7 and section 5 ("`bandBps` must exceed Priya's fee plus her curve's slippage") need correcting in F03: the fee does not use up band width, and a taker's gross price can sit up to one fee beyond the band, on the side that favours Priya. F03 tests must compute the expected execution price from the net input.
