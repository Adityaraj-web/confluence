# Feedback on building with Uniswap v4

From the CONFLUENCE team (ETHGlobal Mumbai, Nov 5-7, 2026). We built a v4 hook with **custom accounting**: `beforeSwap` takes input out of the PoolManager, buys output from a maker's 1inch Aqua strategy, settles it back in, and returns a `BeforeSwapDelta`. Code: `contracts/src/ConfluenceHook.sol`.

Everything below was written down while building, in `docs/DECISIONS.md` and `docs/PROGRESS.md`, and each item names the entry it came from. We have tried to say only what we hit. Where we are guessing at a cause, we say so. We did not keep a page-by-page log of the documentation site, so this is not a docs audit: most of the friction below is about the **code and libraries** we had to read to get things working.

We built against `v4-core` v4.0.0 and `v4-periphery` at commit `c6e4754` (the `main` branch at the time), on a local anvil fork of mainnet using the deployed PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90`.

## What worked well

- **Forking mainnet and using the real PoolManager worked first time.** Pool initialisation, a seed position and swaps all behaved on the fork exactly as on a local deployment. We never needed a mock PoolManager.
- **`Hooks.validateHookPermissions` plus `HookMiner`.** Once we knew the flag bits, mining an address for exactly `beforeSwap` + `beforeSwapReturnDelta` was quick, and the constructor check catches a wrong address immediately.
- **`StateLibrary.getSlot0` (an `extsload` view).** Our other contract (`PoolPriceBandExtruction`, which runs inside 1inch's router, not inside the PoolManager lock) reads the pool's live price with a plain `view` call. That made a stateless price-band contract possible without any callback into the PoolManager. This was the nicest surprise.
- **The accounting is strict, which is what you want.** When we had a delta wrong, the PoolManager reverted rather than silently mis-booking. That is how we knew the sign convention was right: the first passing full fill proved it.
- **`CustomCurveHook` in v4-core is a good reference.** It was the only worked example of take/settle plus a returned delta that we found, and we relied on it.

## Friction, in order of how much time it cost

### 1. There is no `BaseHook` in the `v4-periphery` we could pin (D-17)

Our F04 spec said to extend `BaseHook` from v4-periphery. At the commit we pinned (`c6e4754`, `main`), `lib/v4-periphery` has no `BaseHook.sol` and no `src/utils/`; a search of all of `contracts/lib/` found none. We implemented `IHooks` ourselves: `beforeSwap` live behind an `onlyPoolManager` modifier, the other 13 callbacks reverting `HookNotImplemented`, and `Hooks.validateHookPermissions` in the constructor, copying the pattern of `v4-core/src/test/BaseTestHooks.sol`.

That works, but it means every team has to re-write the same 13 stubs and the `onlyPoolManager` guard, and a mistake there is a security bug. The assumption was in our own spec (we did not record where it came from), so part of this is our mistake. It still cost us a stop-and-decide moment, and another team following the same assumption would hit it too.

**Suggestion:** ship `BaseHook` (or a clearly named equivalent) at a stable, versioned path, and say in the hook docs which tag or commit it lives at. If it was moved, leave a pointer.

Related, smaller: `v4-core` has a release tag (v4.0.0) and we pinned to it, but `v4-periphery` we had to pin to `main`. We did not record why a tag was not usable, so we cannot say whether that is a gap or our mistake.

### 2. The `BeforeSwapDelta` sign convention had to be derived from source (D-17, D-19)

For an exact-input swap, a hook that consumed input `a` and provided output `b` returns `toBeforeSwapDelta(+a, -b)`: specified `+a`, unspecified `-b`. We got there by reading four places and reconciling them:

- `CustomCurveHook.sol:42-46` (`take` then `settle`, then `toBeforeSwapDelta(int128(-params.amountSpecified), int128(params.amountSpecified))`),
- `Hooks.sol:272-276` (`amountToSwap += hookDeltaSpecified`, and the `HookDeltaExceedsSwapAmount` revert),
- `Hooks.sol:305-311` and `PoolManager.sol:222` (the hook delta is booked to the hook and subtracted from the trader's delta).

The "negative `amountSpecified` means exact input" convention plus "the hook's returned `specified` is added to it" is easy to get backwards, and a wrong sign shows up only as a PoolManager revert at the end of the transaction. The only worked example, `CustomCurveHook`, fills the **whole** amount, so it does not show the partial-fill case (hook serves `a` of a larger swap and the pool curve fills the rest). We trusted the `amountToSwap` line for that case and confirmed it only when our own split tests passed.

**Suggestion:** one worked example in the docs of a *partial* fill with a table: `amountSpecified`, what the hook takes, what it settles, the `BeforeSwapDelta` it returns, and the resulting `amountToSwap` for the pool curve. Both swap directions.

### 3. Production code ends up depending on `test/` helpers (D-19, D-21)

None of these is a production-grade path, and all of them are in `test` directories:

- **`CurrencySettler`** (`v4-core/test/utils/`) is how `CustomCurveHook` does `sync` / transfer / `settle` and `take`. Our hook imports it. Our hook is the only thing in the repo that settles, so we depend on a test utility for the core of our accounting.
- **`HookMiner`** is `v4-periphery/test/shared/HookMiner.sol`.
- **`PoolSwapTest`** (`v4-core/src/test/`) is the swap router we use in the demo and tests. It is **not deployed on mainnet**, so on a fork we deploy our own copy. This matters beyond convenience: our gas reserve was measured with it, and a different router needs re-measuring (see 4).

**Suggestion:** move the settle/take helper and the miner out of `test/` into `src/` libraries that are meant to be imported, or document that importing from `test/` is the supported route.

### 4. A hook that makes an external call makes the swap's outcome depend on the gas limit (D-20)

This is not a bug in v4; it follows from calling an external contract inside `beforeSwap` and catching its failure. But it was the hardest thing to get right and we found no guidance on it.

- The 63/64 rule leaves the hook about 1/64 of the gas at each call level above it, so a callee that burns its gas can starve the rest of the swap (the PoolManager's pool-leg continuation ran out of gas in our trace).
- We therefore cap the gas forwarded to the router and keep a reserve for the unwind. We measured the reserve with a sweep: at reserve 70,000 the hinted swap reverted at 17 of 24 gas limits; at 100,000, at 10 limits; from 105,000 up, at none. We use 150,000. **A first attempt that measured one gas limit only gave 49,500, which was badly wrong** (frames above the hook keep 1/64 each, which helps at a large limit and hurts at a small one). Measure across a range of limits.
- The result: in our harness the hook skips the external call below a transaction gas limit of 396,526, and a fill first appears at 458,286. **So `eth_estimateGas`, or a node's default gas limit, can land where the external call is skipped, and the trader silently gets the fallback fill with no error.** Our quoter, scripts and web app all set an explicit gas limit (1,500,000) and simulate at that same limit.
- Caveat we have not closed: the reserve was measured with `PoolSwapTest` and a pool leg that crosses no initialised tick. A heavier router or a tick-crossing pool leg may need more.

**Suggestion:** a short docs section for hooks that call out: how to size a reserve, why `estimateGas` is unreliable for them, and that gas-dependent behaviour should be reported through an event (ours emits `AquaSkipped(poolId, reason)`) so integrators can tell a skip from a fill.

### 5. `take` is bounded by the PoolManager's real balance of that token (D-19, D-22)

`take` is a real transfer out of the PoolManager's global balance, not a credit against the pool. For a long-tail token the PoolManager may hold very little: when a hint exceeded what the manager held of the input token, the swap reverted until we added a pre-check and a skip (`PoolManagerShort`). In the invariant fuzzing we saw the manager holding 3-4 wei of MUMB at the edge of the seed range. A custom-accounting hook that sells a token the pool does not hold much of must check this first. We could not find it mentioned; it may be obvious to experienced v4 developers.

### 6. Price and currency-order bookkeeping (D-18, D-25)

- The v4 price is *raw* currency1 per raw currency0, so with USDC (6 decimals) as currency0 and an 18-decimal token as currency1, 1 token = 1 USDC is `sqrtPriceX96 = 1e6 * 2^96`, and with the order reversed it is `2^96 / 1e6`. Which one you get depends on the address of the token you deploy, which depends on the deployer's nonce, so our tests and script have to branch on `USDC < address(mumb)`. It is correct and well-defined, but it is an easy place for a decimals/orientation error, so we pinned it with a test (`test_F04_anchorPriceBothOrders`).
- We also had to be careful about what "price impact" means: the change in `slot0`'s price (squared `sqrtPriceX96`) is not the change in the token's USDC price when the token is currency1. We label that UI row "pool price move", not "price impact".

### 7. Deployment from a script: the CREATE2 deployer (code comment in `Setup.s.sol`)

For hook mining, a `forge script --broadcast` CREATE2 deploy goes through the deterministic factory, so that factory (not the script's `msg.sender`) is the deployer in the address maths. `Setup.s.sol` checks the mined address against the deployed one (`HookAddressMismatch`) and carries a comment about this. We do not know how many people would trip on it, but it is the kind of thing that is worth a note next to `HookMiner`.

## Smaller notes

- **Custom-accounting hooks are very testable on a fork.** The `test_F05_*` tests assert the hook holds zero tokens after every swap and the PoolManager nets to zero; the invariant suite (`test/invariant/`) does so over thousands of fuzzed swaps. That workflow was pleasant.

## Notes about the other half of our stack (for 1inch, in case useful)

Not Uniswap, but it shaped our hook and nobody else will have written it down:

- **Aqua refuses to ship the same strategy twice, and docking does not free the hash.** `ship` refuses a hash whose tokens already have a non-zero count (`Aqua.sol:48`), and `dock` leaves the count at `0xff`, not 0 (`Aqua.sol:58`). So a maker who docks and wants to re-ship the *same* program must change the bytes. The strategy hash is `keccak256(order)` and does not include the amounts. We added a no-op `Controls._salt` opcode to change the hash without changing any output (`test_F08_saltChangesHashNotOutput`). A documented "re-ship" pattern would help; we found out by hitting the revert.
- **Virtual balances move no tokens.** `ship` and `dock` only write the virtual balance; only `pull`/`push` move wallet tokens. Reasoning about "is the maker's value conserved" meant summing across every strategy she had ever shipped, including docked ones. That is the right design, but it is not obvious from the interface.
- **A SwapVM v1.0.2 / `main` mismatch.** The deployed router is v1.0.2, whose `swap` signature and opcode numbers differ from `main`. We pinned the v1.0.2 tag and the TypeScript SDK at 0.4.0 (0.5.0 has breaking changes). `AquaProgramBuilder` in the SDK has no `.extruction()` method, so we added the step with `.add(...)`; the SDK's `.d.ts` comment says the opcode set has 29 entries and the array has 34.
- **Local snapshots are single-use, in a way that bit our demo (anvil, not Aqua).** `evm_revert` consumes the snapshot id; reverting to it a second time returns `false`. So a repeatable "pool-only, then split, from the same state" demo has to take a new snapshot immediately after every revert. This is anvil behaviour, but any demo of a before/after comparison on a fork will hit it (D-23).

## Summary

The v4 core model (unlock, take, settle, delta accounting) was solid and strict, and reading pool state with `extsload` was excellent. The friction was almost all in the *edges around* the core: a missing `BaseHook`, test-directory helpers doing production jobs, no partial-fill example that we could find, and no guidance on gas for hooks that call out. If we could ask for three things: a versioned `BaseHook`, a worked partial-fill delta example, and a short "hooks that make external calls" gas note.
