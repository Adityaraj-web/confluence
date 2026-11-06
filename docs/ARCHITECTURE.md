# CONFLUENCE architecture

CONFLUENCE runs entirely on a local anvil fork of Ethereum mainnet. Uniswap v4 and 1inch Aqua with its SwapVM router are used exactly as already deployed there. We add one hook, one Extruction target contract, a mock token, scripts and a demo web app. We deploy no SwapVM or Aqua code (D-13).

## 1. Components

| Component | Role | Official or ours | Owner | Feature |
| --- | --- | --- | --- | --- |
| Uniswap v4 PoolManager | Holds every pool; runs swaps inside an `unlock` session; reverts unless every balance nets to zero | Official, mainnet | — | — |
| Swap router (test) | What the trader calls; we deploy v4-core's `PoolSwapTest` on the fork (it is not deployed on mainnet) | Official test helper, deployed by us | T1 | F04 |
| **ConfluenceHook** | `beforeSwap`: decides the Aqua slice, buys it from Priya's strategy, settles it, returns a `BeforeSwapDelta` | Ours | T1 | F04-F06 |
| Aqua registry | Tracks Priya's virtual balances per (maker, app, strategy, token); moves tokens only at trade time | Official, `0x1111113ccf1426a8e30e2bff5e005d929bf6a90a` | — | — |
| AquaSwapVMRouter v1.0.2 | Runs Priya's SwapVM program; the Aqua `app` her strategy is shipped to | Official, `0x111111338c5091e8440b67b168bae16a668ac0de` | — | — |
| **PoolPriceBandExtruction** | Extruction target: reads the v4 pool's live price and reverts if the fill's execution price is outside +/- `bandBps` | Ours (stateless, non-upgradeable) | T2 | F03 |
| Priya's strategy | SwapVM program shipped to Aqua with the canonical router as `app`: fee, curve, then an Extruction step pointing at our band contract | Ours (data) | T2 | F02-F03 |
| MockMUMB | 18-decimal ERC-20 for the long-tail side | Ours | T1 | F01 |
| Setup scripts | Deploy, mine hook address, create and seed pool, approve Aqua, ship strategy, register order | Ours (forge script + TS) | Both | F09 |
| Quoter | Picks the hint off-chain by simulating candidate splits | Ours (TS + viem) | T2 | F07 |
| Demo web app | Maker panel, trader panel, side-by-side comparison, balance meters | Ours (Vite + React) | Both | F10 |

Addresses (keep in sync with `.env`):

| Name | Address | Source |
| --- | --- | --- |
| PoolManager (mainnet) | `0x000000000004444c5dc75cB358380D2e3dE08A90` | Uniswap v4 deployments page (checked Oct 30) |
| Aqua registry | `0x1111113ccf1426a8e30e2bff5e005d929bf6a90a` | 1inch verified-contract-addresses page (checked Nov 5) |
| AquaSwapVMRouter v1.0.2 | `0x111111338c5091e8440b67b168bae16a668ac0de` | 1inch verified-contract-addresses page (checked Nov 5); deployed at mainnet block 25618917 |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | Circle |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | mainnet WETH9 |

1inch's docs say the router's `AQUA()` returns the registry above and its `eip712Domain()` reports name `1inch SwapVM v1.0`, version `1.0.2`. F01 asserts both on the fork.

## 2. Setup flow (once per demo run)

1. Start anvil forking mainnet at `FORK_BLOCK`.
2. Deploy MockMUMB; mint MUMB to Priya and the trader; `deal` USDC to the trader and Priya.
3. Deploy `PoolPriceBandExtruction` (no constructor arguments; everything comes from strategy bytes).
4. Mine a hook address whose low bits enable exactly `beforeSwap` and `beforeSwapReturnDelta`; deploy ConfluenceHook with the PoolManager and the canonical router address.
5. Initialise the MUMB/USDC pool with the hook at the anchor price; add a small in-range seed position.
6. Priya approves MUMB and USDC to Aqua once; ships her strategy (fee, curve, Extruction -> band contract with this pool's key and `bandBps`) to Aqua with `app` = the canonical router.
7. Priya calls `hook.registerOrder(poolKey, order)`.
8. Snapshot the chain. Every demo run reverts to this snapshot.

## 3. One swap, step by step (exact input, trader pays USDC for MUMB)

1. Trader calls the swap router with `amountSpecified` = -1,000 USDC (negative = exact input in v4) and `hookData` carrying the hint `a`.
2. PoolManager opens the unlock session and calls `ConfluenceHook.beforeSwap`.
3. Hook checks: exact input? an order registered for this pool? `a > 0` and `a <= |amountSpecified|`? If not, return a zero delta (pool-only).
4. Hook calls `poolManager.take(USDC, hook, a)`: the hook now holds `a` USDC and owes it to the PoolManager's books.
5. Hook approves the router, the contract that calls `transferFrom` on the taker (D-02), for `a` USDC.
6. Hook calls the canonical router's `swap(order, tokenIn, tokenOut, a, takerTraitsAndData)` inside try/catch (the 5-argument v1.0.2 signature, D-04), with taker traits: exact input, `useTransferFromAndAquaPush = true`, `threshold` = minimum MUMB out, recipient = hook.
7. The router runs Priya's program. The flat fee takes its cut and runs the rest of the program inside itself, so the curve computes `b` from `a` net of the fee. The Extruction step then calls `PoolPriceBandExtruction.extruction(...)`, which reads the pool's `sqrtPriceX96` and reverts if the execution price, net input over `b`, is outside the band (D-15). If it passes, Aqua pulls `b` MUMB from Priya's wallet to the hook; the router pulls `a` USDC from the hook and pushes it into Priya's Aqua balance.
8. Hook settles `b` MUMB into the PoolManager (`sync`, transfer, `settle`).
9. Hook returns `BeforeSwapDelta(specified = +a, unspecified = -b)`: "I consumed `a` of the input and provided `b` of the output." Sign convention checked against v4's custom-curve hook in F04 (D-17); the partial-fill case is exercised by `test_F05_partialSplit` and `test_F05_reverseDirection` (D-19).
10. Pool curve swaps the remaining `1,000 - a` USDC against the seed position.
11. Swap router settles with the PoolManager; trader receives the total MUMB; PoolManager checks all deltas are zero.

If step 6 reverts for any reason (band breached, strategy docked, balance short), the hook has not settled anything yet. It returns the `a` USDC to the PoolManager with `settle` and returns a zero delta, so the pool fills everything. Design of this unwind is F06.

Why the band does not move during steps 6-7: the pool curve only runs after `beforeSwap` returns (step 10), so `slot0` is the same when the hook quotes and when it swaps. Inside one hook call, the band's quote and swap results are identical (D-14).

## 4. Token flow invariants

- After every swap: hook token balances = 0 (MUMB and USDC).
- Priya's wallet: MUMB down by `b`; Priya's Aqua virtual balance: USDC up by `a`, MUMB down by `b`.
- Trader: USDC down by exactly `amountIn`; MUMB up by `b + poolLegOut`.
- PoolManager: no residual deltas (enforced by v4; reverts otherwise).

## 5. PoolPriceBandExtruction

How Extruction works (swap-vm v1.0.2, `src/instructions/Extruction.sol`; opcode index 32 on the canonical router, D-16):
- The program's Extruction step is `opcode (1 byte) | argsLength (1 byte) | target (20 bytes) | extructionArgs (N bytes)`, where `argsLength` covers the target and the args, so at most 255 bytes. The router calls `target.extruction(isStaticContext, nextPC, query, swap, extructionArgs, takerData)`.
- `query` (`SwapQuery`): orderHash, maker, taker, tokenIn, tokenOut, isExactIn. `swap` (`SwapRegisters`): balanceIn, balanceOut, amountIn, amountOut, amountNetPulled.
- It returns `(updatedNextPC, choppedLength, updatedSwap)`, and the router writes those back. A revert in the target reverts the quote or swap.
- `quote()` calls it through `IStaticExtruction` (STATICCALL); `swap()` calls it through `IExtruction` (CALL). Both share one selector, so one `view` function serves both.
- 1inch's two hard rules: the target is non-upgradeable, and quote and swap return identical amounts for the same inputs.

Our target:
- `extructionArgs`, packed and fixed in the strategy: `poolManager (20) | currency0 (20) | currency1 (20) | fee (3) | tickSpacing (3) | hooks (20) | bandBps (2)` = 88 bytes. A `build`/`parse` pair in the contract encodes and decodes this. `parse` reverts `InvalidArgsLength` unless the args are exactly 88 bytes; both revert `InvalidBand` if `bandBps` is 0 or above 10,000. `extruction` parses first, so hand-built strategy bytes get the same checks.
- Computes `poolId = keccak256(abi.encode(poolKey))` from those fields, so the args cannot name a pool whose tokens differ from the swap. Reverts `PoolTokenMismatch` unless `{tokenIn, tokenOut} == {currency0, currency1}`.
- Reads `sqrtPriceX96` with v4's `StateLibrary.getSlot0(poolManager, poolId)` (a view `extsload`). Reverts `PoolNotInitialized` if it is 0.
- Reverts `PoolPriceBandNotComputed` if `amountIn == 0` or `amountOut == 0`. This catches a program that puts the step before the curve. It comes before the price maths, which divides by one of these registers.
- Pool price as currency1 per currency0, Q96-scaled: `poolX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 2^96)`.
- Execution price from the registers, oriented the same way: if `tokenIn == currency0`, `execX96 = mulDiv(amountOut, 2^96, amountIn)`; otherwise `execX96 = mulDiv(amountIn, 2^96, amountOut)`. Inside a flat fee, the `amountIn` register is net of the fee for both exact input and exact output, so the band checks Priya's curve price, not the taker's gross price (D-15).
- Reverts `PoolPriceBandExceeded(execX96, poolX96, bandBps)` if `|execX96 - poolX96| * 10_000 > bandBps * poolX96`, computed as `diff > mulDiv(poolX96, bandBps, 10_000)`, which gives the same result and cannot overflow.
- Returns `(nextPC, 0, swap)` unchanged. It is a pure guard: it never writes amounts, consumes no taker data and never jumps.
- `bandBps` must exceed Priya's curve slippage for the sizes she wants to fill, or those fills are refused. The fee does not use up band width: a taker's gross price can sit up to one fee beyond the band, on the side that favours Priya. The demo uses 30 bps fee and 200 bps band. With 100,000 of each token shipped and the pool at her curve's price, that admits a single fill of up to about 2,047 USDC or 2,006 MUMB. A second 1,000 USDC fill in the same direction is about 2.9% off and is refused unless the pool price has moved too.
- Because the parameters live in the strategy bytes, any maker can point any strategy at this one deployed contract for any v4 pool. That reuse is part of the 1inch pitch.

## 6. ConfluenceHook interface (names and behaviour; no code here)

- Constructor: PoolManager, canonical AquaSwapVMRouter address.
- Permissions: `beforeSwap`, `beforeSwapReturnDelta` only.
- `registerOrder(PoolKey key, Order order)`: caller must equal `order.maker`; stores one active order per `poolId`; emits `OrderRegistered`.
- `unregisterOrder(PoolKey key)`: maker only.
- `hookData`: phase 1 = ABI-encoded `uint256 aquaAmountIn`. Empty = phase 2 search if F12 is built, otherwise pool-only.
- Events: `AquaFill(poolId, maker, amountIn, amountOut)`, `AquaSkipped(poolId, reason)`.
- Holds no funds between swaps; no owner powers over user funds.

Note: Priya's order sits on the canonical router, so any taker can also fill it directly through the router, not only through our hook. The band lives in her program, not in the hook, so it protects her on every path.

## 7. Quoter (off-chain hint)

- Inputs: pool key, trade size, direction.
- Simulates the full swap with `eth_call` at the current block for candidate hints: 0%, 10%, ..., 100% of the trade, then refines between the best two.
- Picks the hint with the highest MUMB out; reports pool-only output, split output and the split.
- Used by the demo runner and the web app; never on-chain.

## 8. Demo comparison

Revert to the snapshot, run the swap with hint 0 (pool-only), record output. Revert again, run with the quoter's hint, record output, split, Priya's balances and the pool's liquidity. Both runs start from the same state, so the comparison is fair.

## 9. Fallback: router-level split (F05-ALT)

If the hook path cannot work by hour 8, a standalone `SplitRouter` contract does, in one transaction: an Aqua swap through the canonical router for `a` (band still enforced by the Extruction step), then a v4 swap for the rest, and sends the trader the total. It keeps both sponsors (Aqua + SwapVM Extruction for 1inch, a v4 pool for Uniswap) but loses "the pool itself is deep".
