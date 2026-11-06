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

## D-16 PoolPriceBandExtruction validation, and the F03 [VERIFY] answers
- Status: Decided (Nov 6)
- Added beyond the F03 spec, approved by the team:
  - `InvalidArgsLength(uint256 length)`: `parse` requires exactly 88 bytes. Without it, short args revert with no named error and extra bytes are silently ignored.
  - `InvalidBand` fires in `build` as well as `parse`. `build` fails fast before a strategy ships; `parse` still checks because strategy bytes can be hand-built.
- Choices the spec left open:
  - `build` and `parse` live on the contract as `pure` functions, so F09 scripts can call them on the deployed contract.
  - `bandBps` is a `uint16` in `PoolPriceBandExceeded`, matching its 2 bytes in the args.
- Corrections to ARCHITECTURE section 5, now applied there:
  - The not-computed check runs before the price maths. In the old order, a misordered MUMB->USDC program divides by a zero `amountOut` and reverts with no named error.
  - The band comparison is `diff > mulDiv(poolX96, bandBps, 10_000)`. For integers it is equivalent to `diff * 10_000 > bandBps * poolX96`, which can overflow when `execX96` is near 2^256.
- F03 [VERIFY] answers, from the v1.0.2 source and a throwaway probe against the deployed router and PoolManager at `FORK_BLOCK`:
  - The Extruction opcode is index 32 (`AquaOpcodes.sol:73`, looked up at runtime) and it ran on the deployed router. A step is `opcode | argsLength | target | args` (`VM.sol:124-127`). Ours is `0x20 0x6c` then 108 bytes, 110 in total; `argsLength` is one byte, so at most 255.
  - `IExtruction` and `IStaticExtruction` have the same signature (`Extruction.sol:17-52`). `SwapQuery` and `SwapRegisters` field order matches ARCHITECTURE section 5 (`VM.sol:33-54`). One `view` function overriding both compiles and runs in `swap` and `quote`.
  - `XYCSwap` is not terminal: it never writes the program counter (`XYCSwap.sol:17-33`). The spec's "place the step where the registers hold the final amounts the taker sees" cannot be met for `amountIn`: the fee restores the gross input only after its nested `runLoop`, which runs to the end of the program (`Fee.sol:86-91`), and a fee after the curve reverts `FeeShouldBeAppliedBeforeSwapAmountsComputation` (`Fee.sol:83`). At the step, a 1,000 USDC swap shows `amountIn` 997000000 and `amountOut` 987158034397061298850. This confirms D-15.
  - `getSlot0` works during an unlocked session: `extsload` has no lock modifier (`Extsload.sol:10`). The probe read the same `sqrtPriceX96` inside `unlock` as outside it on the live PoolManager, with `isUnlocked()` true inside, and also read it from an Extruction target in the router's `quote` STATICCALL. An uninitialised pool reads 0. The probe was not committed, so no repo test covers the read inside `unlock` until F05.

## D-17 The hook implements `IHooks` directly; the `BeforeSwapDelta` sign convention (F04 [VERIFY])
- Status: Decided (Nov 6)
- No `BaseHook`: the F04 spec says to extend v4-periphery's `BaseHook`, but `lib/v4-periphery` (c6e4754, `heads/main`) has no `BaseHook.sol` and no `src/utils/`; a search of all of `contracts/lib/` finds none. `ConfluenceHook` implements `IHooks` itself: `beforeSwap` is live behind `onlyPoolManager`, the other 13 callbacks revert `HookNotImplemented` (the pattern of `lib/v4-core/src/test/BaseTestHooks.sol`, which we do not inherit because it is a test helper), and the constructor calls `Hooks.validateHookPermissions` (`Hooks.sol:82`), as `BaseHook` did. No new submodule (approved by the team). The F04 spec line is corrected.
- Sign convention, exact input: a hook that consumed input `a` and provided output `b` returns `toBeforeSwapDelta(+a, -b)`, i.e. specified = `+a`, unspecified = `-b`. This is what ARCHITECTURE section 3 step 9 says, now confirmed against the source:
  - `lib/v4-core/src/test/CustomCurveHook.sol:42-43`: `manager.take(input, hook, amount)` then `output.settle(manager, hook, amount, false)`.
  - `CustomCurveHook.sol:46`: returns `toBeforeSwapDelta(int128(-params.amountSpecified), int128(params.amountSpecified))`. On exact input `amountSpecified = -a`, so that is `(+a, -a)`.
  - `Hooks.sol:272-276`: `amountToSwap += hookDeltaSpecified`, so the pool curve swaps `-(|amountSpecified| - a)`; it reverts `HookDeltaExceedsSwapAmount` if that flips the sign, so `a <= |amountSpecified|` is enforced by v4 as well.
  - `Hooks.sol:305-309` and `PoolManager.sol:222`: the hook delta is accounted to the hook address (the `take` of `a` nets against `+a`, the `settle` of `b` against `-b`) and subtracted from the trader's `swapDelta`.
- Limit of this check: `CustomCurveHook` fills the whole amount. The partial case follows from the `amountToSwap` line above but is not exercised by a repo test until `test_F05_fullAquaFill` and the split tests. A wrong sign makes the PoolManager revert, so F05 will show it at once.
- F04 hook skeleton: also confirmed on the fork that a hook with `beforeSwapReturnDelta` set and a zero delta leaves swaps unchanged (`test_F04_beforeSwapZeroDeltaSwapEqualsNoHookSwap`).

## D-18 F04 hook interface details the spec left open; anchor price; seed
- Status: Decided (Nov 6)
- Constructor `(IPoolManager, address router)`. Events `OrderRegistered(PoolId indexed poolId, address indexed maker, bytes32 orderHash)` with `orderHash = keccak256(abi.encode(order))` (the Aqua-order hash, per `ISwapVM.hash`'s NatSpec), and `OrderUnregistered(PoolId indexed poolId, address indexed maker)`. Errors `NotMaker`, `NotPoolManager`, `NoOrder`, `HookNotImplemented`. A getter `orderOf(PoolId)` returns the stored `ISwapVM.Order` (`maker` is zero when none). `unregisterOrder` checks `NoOrder` before `NotMaker`.
- `registerOrder` replaces any earlier order for the pool, whoever registered it (D-09: one order per pool). Only `order.maker == msg.sender` is checked, so a second maker can displace the first. This can only switch off the Aqua leg for that pool, never fail a swap. Revisit in F06 if it matters.
- Anchor price, 1 MUMB = 1 USDC (the second F04 [VERIFY]): v4 price is raw currency1 per raw currency0. With USDC as currency0, price = 1e18 / 1e6 = 1e12, so `sqrtPriceX96 = 1e6 * 2^96`. With MUMB as currency0, price = 1e-12, so `sqrtPriceX96 = 2^96 / 1e6`. Both are exact square roots. The currency order depends on `address(mumb)`, which depends on the deployer nonce, so the test base branches on it; at `FORK_BLOCK` USDC (0xA0b8...) is currency0. The anchor ticks are about +/-276,324 (`test_F04_anchorPriceBothOrders`).
- Seed position: 2,500 USDC and 2,500 MUMB offered, over the anchor tick rounded to spacing 60 plus and minus 600 ticks (about +/-6%), liquidity from `LiquidityAmounts.getLiquidityForAmounts`. A 1,000 USDC pool-only buy moves the tick from 276,324 to 276,080 (about 2.4% in price), which stays in range, and returns 984.934194542570551127 MUMB. F05 to F08 should expect a pool swap of that size to move `slot0` by more than a 200 bps band.

## D-19 F05: the Aqua leg inside the hook
- Status: Decided (Nov 6)
- Result: `test_F05_fullAquaFill` passes, so the hook can be the Aqua taker on the canonical router inside `beforeSwap`. Hour-8 gate met; F05-ALT is not needed. D-02's "not covered by F02" item is closed.
- Checked in the source (v4-core and swap-vm v1.0.2):
  - `take` and `settle` need only an unlocked PoolManager (`PoolManager.sol:289-304`) and book deltas to the caller, the hook. The returned `BeforeSwapDelta` is booked to the hook (`PoolManager.sol:222`) and subtracted from the trader's delta (`Hooks.sol:311`), so the hook's `-a` (take) and `+b` (settle) net against `+a` and `-b`.
  - `take` is a real transfer out of the PoolManager's global balance, so it needs `a` on hand. USDC is always there. MUMB is ours, so the PoolManager holds only the seed's MUMB (2,500e18): a MUMB-input hint above that reverts the swap in F05. The band caps one fill at about 2,006 MUMB, so demo sizes fit. F06 must guard it.
  - The router's taker is `msg.sender`, the hook (`SwapVM.sol:179`); the output goes to the hook because `to` is zero (`SwapVM.sol:266`). The per-order lock (`SwapVM.sol:164`) trips only if the same order re-enters; F06's try/catch turns that into a pool-only fill.
- Choices the spec left open:
  - `CurrencySettler` comes from `v4-core/test/utils/` (the helper `CustomCurveHook` uses). Nothing else in the repo settles.
  - Skip checks run cheapest first: exact output or `hookData` not 32 bytes, then `a == 0` or `a > |amountSpecified|` (computed without overflow at `int256.min`), then no registered order.
  - The minimum output passed to the router is 1; the trader's price limit and the band are the real protection.
  - OpenZeppelin `SafeCast.toUint256` (aliased `OZSafeCast`) for the `int256` to `uint256` step; v4's `SafeCast` has none. Two forge-lint disables, each with its reason: `unused-return` (only `b` is used; the router's check makes the amount in equal `a`) and `reentrancy-events` (`b` is known only after the call).
  - `AquaSkipped` is not in F05: skips are silent, and F06 designs the event with the router's revert data.
- Partial fills confirm D-17's sign: `(+a, -b)` with a hint below the swap amount, and in both directions.
