# F05 Aqua leg inside the hook (phase 1, hint)

- Owner: T1 + T2 (pair on one laptop)
- Depends on: F03, F04
- Architecture: sections 3, 4, 6
- Decisions: D-02, D-05, D-08, D-09
- **Hour-8 gate:** `test_F05_fullAquaFill` must pass by hour 8, or we move to F05-ALT.

## Goal
On an exact-input swap with a hint `a`, the hook fills `a` of the input from Priya's Aqua strategy inside the same swap, and the pool fills the rest.

## Files
- `contracts/src/ConfluenceHook.sol`
- `contracts/test/base/ConfluenceBase.t.sol` (extends PoolBase: deploys `PoolPriceBandExtruction`, ships Priya's strategy with the band step to the canonical router, registers her order)
- `contracts/test/fork/F05AquaLeg.t.sol`

## Behaviour
Follow ARCHITECTURE section 3 steps 3-9 exactly:
1. Decode `a` from `hookData`. Skip Aqua (zero delta) if: exact output, no order registered, `a == 0`, or `a > |amountSpecified|`.
2. `take` `a` of the input currency from the PoolManager to the hook.
3. Approve the transfer-from party (per D-02) for exactly `a`.
4. Call the canonical router's 5-argument `swap` with Priya's order, tokenIn, tokenOut, `a`, and taker data: taker = hook, exact input, direction from the pool's `zeroForOne`, `useTransferFromAndAquaPush = true`, recipient = hook, a minimum-out threshold of 1 (real slippage protection is the trader's `sqrtPriceLimit` and the band).
5. Settle the received output `b` into the PoolManager.
6. Return the delta for `+a` specified and `-b` unspecified (per the F04 sign-convention entry).
7. Emit `AquaFill`.
- No try/catch yet; F06 adds it. Reset approvals to zero after the call.

## Out of scope
Failure handling, on-chain search, exact-output Aqua fills, multiple makers.

## Acceptance
- `test_F05_fullAquaFill`: hint = 100% of 1,000 USDC. Trader gets MUMB > 0; Priya's wallet MUMB down by the same amount; Priya's Aqua USDC up by 1,000; pool's in-range liquidity unchanged; hook balances zero.
- `test_F05_partialSplit`: hint = 60%. Trader's MUMB = Aqua leg out + pool leg out (from events); all invariants in ARCHITECTURE section 4 hold.
- `test_F05_splitBeatsPoolOnly`: from one snapshot, pool-only output < split output for 1,000 USDC.
- `test_F05_reverseDirection`: MUMB -> USDC with a hint works.
- `test_F05_zeroHintIsPoolOnly`: hint 0 behaves exactly like F04.

## If blocked
If the router call inside `beforeSwap` cannot work (reentrancy lock, callback ordering, approvals), capture the revert reason and trace, add it to PROGRESS.md, and tell the team immediately. That evidence decides F05-ALT at hour 8.
