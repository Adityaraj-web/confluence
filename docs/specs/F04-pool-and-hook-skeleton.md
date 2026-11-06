# F04 Pool, seed position and hook skeleton

- Owner: T1
- Depends on: F01
- Architecture: sections 1, 2 (steps 4-5), 3 (steps 1-2, 9-11), 6

## Goal
A MUMB/USDC v4 pool with our hook attached, a seed position, and pool-only swaps that work. The hook exists with its final permissions and storage but does no Aqua work yet.

## Files
- `contracts/src/ConfluenceHook.sol`
- `contracts/test/base/PoolBase.t.sol` (extends ForkBase: deploys hook via address mining, inits pool, adds seed, deploys a swap router test helper)
- `contracts/test/fork/F04PoolSkeleton.t.sol`

## Behaviour
- Hook implements `IHooks` directly, because v4-periphery in `lib/` has no `BaseHook` (D-17); permissions `beforeSwap` and `beforeSwapReturnDelta` only.
- Address mined with `HookMiner`, deployed with CREATE2.
- `registerOrder` / `unregisterOrder` and storage per `poolId` as in ARCHITECTURE section 6 (the order type comes from SwapVM; F04 may store it without using it).
- `beforeSwap` returns a zero delta and zero fee override for now.
- Pool: fee 3000, tick spacing 60, initialised at an anchor price of 1 MUMB = 1 USDC (adjust for decimals: currency order and 18 vs 6 decimals).
- Swap router: deploy v4-core's `PoolSwapTest` (and `PoolModifyLiquidityTest` for the seed) in the test base; neither exists on mainnet.
- Seed: a small in-range position, about 5,000 USDC of value, from the deployer.

## Out of scope
Any Aqua call.

## Acceptance
- `test_F04_hookPermissions`: the hook address flags match exactly the two permissions.
- `test_F04_poolOnlySwap`: trader swaps 1,000 USDC exact input, receives MUMB > 0, hook balances are zero.
- `test_F04_registerOrderMakerOnly`: a non-maker caller reverts; the maker succeeds and the event fires.
- `test_F04_exactOutputStillWorks`: an exact-output swap succeeds pool-only.

## [VERIFY]
- `BeforeSwapDelta` sign convention for "hook consumed input, provided output" in exact-input swaps. Find v4's custom-accounting example tests (custom curve hooks) and cite file and line in a DECISIONS entry. F05 depends on this.
- How to compute `sqrtPriceX96` for the anchor price given 18 and 6 decimals and the actual currency order.
