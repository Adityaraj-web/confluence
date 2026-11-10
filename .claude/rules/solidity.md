---
paths:
  - "contracts/**/*.sol"
---

# Solidity rules

- Solidity 0.8.30. Our files use `// SPDX-License-Identifier: MIT`; any vendored 1inch interface file keeps its own header.
- Custom errors, not revert strings. Name them for the condition: `PoolPriceBandExceeded`, `NotMaker`.
- No `tx.origin` anywhere in our code.
- Use v4's `StateLibrary`, `CurrencySettler`-style helpers and `BalanceDelta` / `BeforeSwapDelta` types; never hand-roll delta packing.
- Use full-precision mul-div (`FullMath`) for any price maths. No intermediate value may overflow at `sqrtPriceX96` near its bounds.
- Approvals in the hook: approve exactly the amount needed, reset to zero after the call.
- Events for every state change and every Aqua fill or skip.
- Every external function in our contracts has a NatSpec line saying who may call it.
- Tests: `test_V2xx_<behaviour>` names for v2 (`test_F0X_` for v1 history); assert exact balances, not just "greater than zero", once amounts are known.
- Never edit `contracts/lib/`. If a dependency needs a change, stop and ask.
- Never deploy, fork or modify SwapVM or Aqua contracts. Call the canonical addresses.
- `BandGuardV2` (and v1's `PoolPriceBandExtruction`): no storage variables, no immutables that change behaviour, no owner, no proxy, exactly one `view` `extruction` function; it reverts or returns the registers unchanged.
- SwapVM opcode indices come from `AquaOpcodes._opcodes()` in `contracts/lib/` (v1.0.2), never typed in from docs.
- v2: every loop is bounded by a named constant (`MAX_STRATEGIES`, `MAX_LEGS`, `MAX_TICK_RANGES`). No unbounded iteration over storage.
- v2: the hook has no owner, admin, proxy, fee switch or pause. Libraries are pure or view.
