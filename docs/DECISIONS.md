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
- `registerOrder` replaces any earlier order for the pool, whoever registered it (D-09: one order per pool). Only `order.maker == msg.sender` is checked, so a second maker can displace the first. This can switch off the Aqua leg for that pool, and never fails a swap. **Amended by D-20 (F06):** it can also make a swap cost more gas, because a registered strategy can burn all the gas the hook forwards to the router. The forward is capped at `MAX_AQUA_GAS` (640,000), so the cost to a trader is bounded and the swap still passes. A very large `order.data` also costs gas on every swap, to load from storage and to encode into the router call; that is not bounded yet and is an open issue for F08 (a size limit in `registerOrder`).
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

## D-20 F06: Aqua can never fail a swap: unwind, skip cases, gas
- Status: Decided (Nov 6). Implements D-06.
- Result: the five acceptance tests and ten extra tests in `F06Safety.t.sol` pass (15); `forge test` passes 64 (49 earlier + 15). `spec-reviewer` found every Behaviour and Acceptance line met.
- Unwind: the router call is inside `try`/`catch`. A router failure undoes everything the router did, so the hook holds exactly the `a` it took. It resets the approval to 0, settles `a` back to the PoolManager, emits `AquaSkipped(poolId, reason)` and returns a zero delta. Only the router call is inside the try: the settlement of `b` after a success, the `b.toInt128()` cast and the decoding of the router's return are not.
- Skip events (the spec left this open). A swap that asked for an Aqua leg, meaning a non-zero 32-byte hint, and is skipped emits `AquaSkipped`. A swap that did not ask (empty or other-length `hookData`, or a hint of 0) is pool-only and silent, so ordinary pool swaps add no log. Pre-call checks, cheapest first: exact output (`ExactOutputNotSupported`), hint above the amount (`HintAboveAmount`), hint above int128 max (`HintTooLarge`), no order (`NoOrder`), PoolManager holds less of the input token than the hint (`PoolManagerShort(available)`, which F05 left as a revert), `gasleft()` under `AQUA_GAS_RESERVE + MIN_AQUA_GAS` (`InsufficientGas(gasLeft)`). `reason` is an ABI-encoded custom error; for a router failure it is the router's own revert data.
- Revert data is trimmed to `MAX_REASON_BYTES` = 256 (`returndatacopy` of a bounded prefix, not `catch (bytes memory)`). `registerOrder` accepts any maker (D-18), so the revert data of a maker-chosen Extruction is untrusted; the event would cost 8 gas per byte and the copy more. Out of gas leaves no data, so the reason is empty.
- Checked in the source:
  - Docked strategy: `Aqua.dock` stores `(0, DOCKED)` (`Aqua.sol:54-61`); `safeBalances` then reverts `SafeBalancesForTokenNotInActiveStrategy(maker, app, hash, token)` (`Aqua.sol:32`), and the router calls it first (`SwapVM.sol:194`), before any transfer.
  - "Hint larger than her virtual balance": the XYC curve gives `amountOut = in * balOut / (balIn + in)` (`XYCSwap.sol:22-24`), always below `balOut`, so a fill can never overdraw her virtual balance and the underflow in `Aqua.pull` (`Aqua.sol:66`) is unreachable. What refuses such a hint is the band (`PoolPriceBandExceeded`); `test_F06_insufficientMakerBalanceFallsBack` tests that. The real balance failure is her wallet holding less than her virtual balance, so `test_F06_makerWalletShortFallsBack` was added.
  - Revoked approval and short wallet both fail in `Aqua.pull`'s `safeTransferFrom` (`Aqua.sol:68`), through 1inch's `SafeERC20`, which reverts `SafeTransferFromFailed()` rather than passing the token's error up.
  - Order of events in `swap` (`SwapVM.sol:156-215`): lock, safeBalances, program (band), transfer out (pull), transfer in. A failure at any point reverts all of it.
- int128. Two conversions. The hint `a` is checked against int128 max before anything is taken (`HintTooLarge`). `b.toInt128()` runs after the router call, outside the try/catch, and is accepted. It is not enough to say `b` is at most a `uint248` (Aqua's balance type): `uint248` is larger than `int128`, so that does not prove `b` fits. The reason is that the band holds the fill to roughly `a` times the pool price and `a` is already capped at int128 max, so `b` can overflow only at an absurd pool price. A revert there reverts the whole swap, with no tokens stranded.
- Gas. The router gets `min(gasleft - AQUA_GAS_RESERVE, MAX_AQUA_GAS)`, and the hook skips Aqua when `gasleft` is under `AQUA_GAS_RESERVE + MIN_AQUA_GAS` at the check. Constants (all `public constant`): `AQUA_GAS_RESERVE` 150,000, `MIN_AQUA_GAS` 160,000, `MAX_AQUA_GAS` = 4 * `MIN_AQUA_GAS` = 640,000. Why a cap is needed at all: with no cap, the 63/64 rule leaves the hook about 1/64 of the gas at each call level, and a strategy that burns its gas starves the rest of the swap.
- Measurements and method:
  - `MIN_AQUA_GAS`: gas of the router call in `test_F05_fullAquaFill` 152,432, `test_F05_partialSplit` 152,432, `test_F05_reverseDirection` 153,418 (from `forge test -vvvv`, identical with `--isolate`). The largest, rounded up to the next 10,000, gives 160,000. The hook's own work around the call (`take`, `approve`, set-up, unwind, event) is about 106,000 (`beforeSwap` 258,598 less the call).
  - `AQUA_GAS_RESERVE`: a scratch probe, not committed, with the reserve temporarily a storage variable set with `vm.store`. For each reserve and each transaction gas limit it ran the pool-only swap and the hinted swap from the same snapshot with `swapRouter.swap{gas: limit}`, for two strategies (Priya's legitimate fill; `GasBurnExtruction`, which executes `INVALID`). The criterion is that the hinted swap never reverts where the pool-only swap passes. Pass 1: 24 limits from 285,000 to 3,000,000. Pass 2: 52 limits, 285,000 to 500,000 in steps of 5,000 plus 550,000, 600,000, 700,000, 800,000, 1,000,000, 1,500,000, 2,000,000, 3,000,000.
  - Results: reserve 70,000 reverts at 17 of 24 limits for the burning strategy (310,000 to 1,000,000) and 4 for the legitimate one (320,000 to 360,000). Reserve 100,000 reverts at 10 limits (335,000 to 380,000) and 13 (345,000 to 405,000) of 52. Reserves 105,000, 110,000, 115,000, 120,000, 125,000 (and 130,000, 160,000, 200,000, 250,000 and 300,000 in pass 1) revert at none. The measured need is 105,000; 150,000 is that plus 43%.
  - A first attempt measured one limit only (1,500,000) and found 49,500 (49,000 reverts). That is too small: the call frames above the hook each keep 1/64 of their gas, which helps at a large limit and not at a small one. An attempt to patch the constant in the compiled bytecode changed only one of its uses and was discarded.
  - Before the cap, at HEAD 961b992: the burning strategy's swap passes from a 2,000,000 limit up and reverts at 1,800,000 and below; the legitimate fill passes down to 400,000 and reverts at 350,000. The trace at 1,500,000 shows the hook catching the failure and unwinding, then the PoolManager's pool-leg continuation running out of gas.
  - `MAX_AQUA_GAS`: at a 3,000,000 limit the burning strategy cost 2,604,386 gas more than a pool-only swap before the cap and 726,414 after (the test bound is the cap plus 150,000).
  - Transaction limits in this harness (logged by `test_F06_gasJustBelowThresholdSkipsWithInsufficientGas`): up to 396,525 the hook skips Aqua with `InsufficientGas`; from 396,526 it tries; Aqua first fills at 458,286.
  - Committed guards: `test_F06_neverCostsTheSwapAtAnyGasLimit` repeats the 52-limit sweep; with the reserve set to 100,000 it fails at limit 345,000.
- The reserve was measured with v4-core's `PoolSwapTest` as the swap router and a pool leg that crosses no initialised tick. A swap router that does more after `beforeSwap`, or a pool leg crossing ticks, needs more, and no test covers that. This is the main residual risk against "Aqua can never fail a swap" and is stated in the NatSpec.
- Accepted: just above the `InsufficientGas` threshold the router can get less than a fill needs, because the check does not count the hook's own gas before the call. The call then runs out of gas, is caught like any failure, and the pool fills the swap.
- **Warning for F07, F09 and F10: behaviour now depends on the transaction's gas limit.** Below 396,526 the hook skips Aqua, and a fill needs about 458,300 in this harness, so `eth_estimateGas`, or a node's default, can land where Aqua is skipped and the trader gets the pool-only fill with no error. The quoter (F07), the demo runner (F09) and the web app (F10) must set an explicit gas limit on the swap transaction (for example 1,500,000) and simulate at the same limit, so the simulated split is the split the transaction gets. The demo should read `AquaFill` / `AquaSkipped` from the receipt rather than assume a fill.
- Open issues:
  - Order size (for F08): `registerOrder` has no limit on `order.data`. A large order costs gas on every hinted swap, to load and to encode, before the gas check. Add a size limit in `registerOrder` and a test.
  - Not covered by a test, per `spec-reviewer`: a router that returns fewer than 96 bytes on success (the decode is in the hook's frame and would revert the swap; the canonical router cannot do this); a failure of `settle(b)` after a success (an output token that blocks the PoolManager); a router that sends more than `b` and leaves dust (`settle` uses the return value, not a balance difference).
  - The gas-spent-before-the-call edge above.
- Lint: one `forge-lint` disable, `reentrancy-events` on `AquaSkipped`, for the same reason as `AquaFill`: the reason is known only after the router call and the PoolManager is locked against re-entry during it. The F05 `unused-return` disable is gone with the try.
- Tests: acceptance `test_F06_bandBreachFallsBack`, `test_F06_dockedStrategyFallsBack`, `test_F06_insufficientMakerBalanceFallsBack`, `test_F06_makerRevokedApprovalFallsBack`, `test_F06_unregisteredOrderIsPoolOnly`; extra `test_F06_makerWalletShortFallsBack`, `test_F06_mumbHintAbovePoolManagerFallsBack`, `test_F06_hintAboveInt128FallsBack`, `test_F06_routerOutOfGasFallsBack`, `test_F06_returnBombFallsBack`, `test_F06_skipReasons`, `test_F06_successPathUnchanged`, `test_F06_neverCostsTheSwapAtAnyGasLimit`, `test_F06_gasJustBelowThresholdSkipsWithInsufficientGas`, `test_F06_burningStrategyCannotBurnMoreThanTheCap`. The return-bomb target reverts with 100,000 bytes: 500,000 needs more gas than the cap forwards, so the router runs out of gas first, which is also caught.

## D-21 F07: quoter choices, and Setup.s.sol pulled forward from F09
- Status: Decided (Nov 6). The F07 spec left these open; the team agreed to pull the setup forward so F07's live acceptance can run.
- Pulled forward from F09: `contracts/script/Setup.s.sol` (ARCHITECTURE section 2, steps 2 to 7) and `deployments/local.json` (written by it). Timebox was 90 minutes; it finished well inside. F09 still owns step 8 (the snapshot), `shipStrategy.ts`, `demo.ts`, the Makefile targets and the demo guard. When F09 starts, extend or replace this script rather than writing a second one. It duplicates the pool maths of `PoolBase._createPool` (anchor price, tick rounding, seed range) because a script cannot inherit the test base; if one changes, change both.
- Funding is real, not an override: the script sets the USDC balances of Priya, the trader and the deployer by writing anvil's storage (`vm.rpc("anvil_setStorageAt")`, slot 9 of Circle's `FiatTokenV2_2`, `balanceAndBlacklistStates`), then requires `balanceOf` to match. MUMB is minted. The trader approves the swap router, so `eth_call` needs no state override. `vm.deal` and `vm.store` do not reach the node from a broadcast script.
- Swap router: v4-core's `PoolSwapTest`, deployed by the script (the same one every test uses). D-20's gas reserve was measured with it; a different router in F09/F10 means re-measuring and quoting through that router.
- Files outside the F07 list that changed: `contracts/foundry.toml` (`fs_permissions` read-write on `../deployments`, so the script can write the JSON; `deployments/` must exist, so it holds a `.gitkeep`) and `scripts/package.json` (`quote`, `test`, `test:int`, `abis`). No dependency was added: `tsx` was already a devDependency and the tests use `node:test`.
- Environment note: the script reads `DEPLOYER_PRIVATE_KEY`, `PRIYA_PRIVATE_KEY` and `TRADER_PRIVATE_KEY`. They are in `.env.example` (anvil's public keys) but were missing from this machine's `.env`; the run sourced `.env.example` first, then `.env`. Add the three lines to `.env`.
- Quoter choices:
  - The hint is `abi.encode(uint256)`. Hint 0 is sent encoded, not as empty `hookData`; `test_F07_live_hintZeroEqualsPoolOnlyPath` shows the output equals the empty-`hookData` swap.
  - Search: hints `amountIn * i / 10` for i = 0..10 (so 100% is exactly `amountIn`), then 5 points `lo + (hi - lo) * k / 6` between the best two usable coarse points. A hint already simulated is not simulated again (at most 16 calls). If fewer than two points are usable, there is no refinement.
  - A reverted simulation is unusable: never chosen, never read as zero. A transport failure (`HttpRequestError`, `TimeoutError`) is re-thrown, not counted as a revert. Hint 0 reverting is an error (no baseline).
  - Ties go to the smaller hint (the same output with less Aqua).
  - `aquaShare` is `hint / amountIn` as a number in [0, 1], rounded down to 6 decimals. `SWAP_GAS_LIMIT` (1,500,000) is exported from `config.ts`, not added to the return value, so the spec's `{ hint, poolOnlyOut, splitOut, aquaShare }` is unchanged.
- Limit: `eth_call` returns no logs, so the quoter cannot see `AquaSkipped`. A hint whose Aqua leg is skipped simply shows the pool-only output and loses to a better one; the demo runner (F09) must still read `AquaFill` / `AquaSkipped` from the real receipt (D-20).
- Measured on the fork at `FORK_BLOCK`, 1,000 USDC to MUMB: pool-only 984.934194542570551127; 60% 991.498196999760649578; 100% 987.158034397061298850 (the same numbers as F05's tests); best 55% (hint 550000000) 991.549823315669231761, after the 5 refinement points.
- The simulated output was compared with a real transaction (`realSwapMatchesQuote`). The quote is for the current block; a second fill in the same direction is subject to the band (PROGRESS, F03).
- Tests: unit `quoter.test.ts` (17, named `test_F07_*`, no chain); live `quoter.live.test.ts` (6, `pnpm --dir scripts test:int`, fails without an anvil): `realSwapMatchesQuote` (a real swap from the trader at 1,500,000 gas inside an `evm_snapshot` that is reverted: the trader gains exactly the quoted `splitOut`, 991549823315669231761 MUMB; `AquaFill` amountIn is the hint, 550000000; `AquaFill` out 545359521066233309646 plus the pool leg 446190302249435922115 equals `splitOut`; no `AquaSkipped`; gas used 331,781), `splitBeatsPoolOnly`, `hintZeroEqualsPoolOnlyPath`, `gasLimitChangesTheSplit` (the chosen hint gives the split at 1,500,000 and the pool-only output at 300,000, which is D-20 on a real chain), `chosenHintIsMaxOfAllSimulatedPoints`, `mumbToUsdcWorks`. The unit test `hintZeroEqualsPoolOnly` is close to a tautology (the search reads `poolOnlyOut` from the hint-0 result); the live test is the real check.

## D-22 F08: how the invariant handler models Priya, the band check and the ghosts
- Status: Decided (Nov 6). The F08 spec left these open ("Priya docks and re-ships" and "value conserved" need a precise meaning). The anchor-recovery fallback (Step 5 of the plan) is recorded here too if it is used; see the last bullet.
- Re-shipping needs different strategy bytes. Aqua's `ship` refuses a hash whose tokens already have a non-zero count (`lib/aqua/src/Aqua.sol:48`), and `dock` leaves the count at `0xff`, not 0 (`Aqua.sol:58`), so shipping the same bytes again reverts. The strategy hash is `keccak256` of the order (`Aqua.sol:41`; the amounts are not in it). The handler prefixes the program with `Controls._salt` (a no-op opcode in the canonical set, `AquaOpcodes.sol:61`, `Controls.sol:70`) holding a counter, so each re-ship has a new hash. `test_F08_saltChangesHashNotOutput` shows that the salt changes the hash and changes no amount of a 1,000 USDC full fill.
- Redock design: Priya docks, then ships 10,000 to 100,000 MUMB with **USDC = MUMB x the pool's current price** (three times in four), so her curve starts at the pool's price; a maker who re-ships to where the market is. One time in four she ships at the anchor price, 1 MUMB = 1 USDC, which is stale once the pool has moved. Random USDC amounts were rejected: her curve would sit far outside the 200 bps band and Aqua would be refused for the rest of the run, so the invariants would only ever see skips.
- `makerValueConserved`, precisely. `ship` writes a virtual balance and moves no tokens, and `dock` zeroes it and moves no tokens (`Aqua.sol:49`, `:58`); only `pull` and `push` move wallet tokens, and each changes the virtual balance by the same amount (`Aqua.sol:66-68`, `:74-78`). So "wallet change equals virtual balance change" holds per token only when the virtual change is summed over every strategy she shipped, counting the balance just before the dock for a docked one, minus what she shipped. The handler keeps those as ghosts (`Strategy` records) and the invariant compares them with her wallet change since the handler was built.
- `noAquaFillOutsideBand` uses its own copy of the extruction's maths, with its rounding: the input is the fill's `amountIn` net of the 0.30% fee (`a - ceilDiv(a * fee, 1e9)`, as `Fee.sol:89`), `poolX96 = mulDiv(s, s, 2^96)`, `execX96 = mulDiv(out, 2^96, net)` when currency0 is the input and `mulDiv(net, 2^96, out)` otherwise, and the fill is inside the band when `diff <= mulDiv(poolX96, bandBps, 10_000)` (`PoolPriceBandExtruction.sol:63-77`). `s` is the pool price read just before the swap, which is the price `beforeSwap` reads, because the pool curve runs after the hook (ARCHITECTURE section 3). `AquaFill` carries no price, so the check rebuilds it from `amountIn`, `amountOut` and the direction.
- Price stays in the seed range. Every handler swap has `sqrtPriceLimitX96` at the seed range's bound in its direction, and a swap whose limit is already passed is not made, so there are no `PriceLimitAlreadyExceeded` reverts and the price never leaves the liquidity. A swap that reaches the limit fills partly, which v4 allows.
- Hints are on a 1% grid, 1% to 100% of the input, plus 0 and 100%. A raw random hint gave dust (a sample was 1,977 wei of MUMB), for which the router refuses a zero output; the hook skips correctly, but dust crowded out real fills. Sizes are 200 to 2,000 units for traders and 1 to 500 for the arbitrageur, so repeats of the same size are refused by the band (F03, PROGRESS).
- `PoolManagerShort` skips are expected, not a bug: when the pool's MUMB has been bought out (a sample shows `available` = 4 wei), a MUMB-in hint exceeds what the PoolManager holds and the hook skips (D-20). In the F08 setup this is the only skip that is not a band skip.
- No pass/fail guard on per-run counters. Foundry resets state between invariant runs, so a counter guard in `afterInvariant` would fail by chance. The counters are logged, with process-level totals across runs (via `vm.setEnv`, which the reset does not touch), and non-vacuity is the deterministic `test_F08_handlerReachesFillAndSkip`.
- "Within the band" statistic (PROGRESS only): the share of swap calls that began with the pool price within the band of Priya's live marginal price, taken as the ratio of her virtual balances (fee ignored). It decides nothing.
