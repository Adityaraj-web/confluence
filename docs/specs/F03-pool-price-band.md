# F03 PoolPriceBand extruction

- Owner: T2
- Depends on: F02
- Architecture: sections 1, 5
- Decisions: D-07, D-13, D-14

## Goal
A stateless Extruction target that refuses any Aqua fill whose execution price is more than `bandBps` away from the v4 pool's live price. Priya's program calls it through the canonical router's Extruction opcode. No router changes, no new opcode.

## Files
- `contracts/src/PoolPriceBandExtruction.sol`: implements both `IExtruction` and `IStaticExtruction` from swap-vm v1.0.2 with ONE `view` function `extruction(...)`. Also exposes `build(...)` and `parse(bytes)` for the 88-byte args (pure; may be a library in the same file).
- `contracts/test/unit/F03PoolPriceBand.t.sol`
- `contracts/test/fork/F03BandOnFork.t.sol`
- `contracts/test/base/StrategyLib.sol` (add the Extruction step to Priya's program)

## Behaviour
- Follow ARCHITECTURE section 5 exactly: args layout, poolId derivation, token-match check, `getSlot0` read, Q96 price maths with `FullMath`, band check, named errors.
- Errors: `PoolTokenMismatch`, `PoolNotInitialized`, `PoolPriceBandNotComputed`, `PoolPriceBandExceeded(execX96, poolX96, bandBps)`, `InvalidBand` (`bandBps` 0 or > 10,000).
- Returns `(nextPC, 0, swap)` unchanged: no register writes, no taker data consumed, no jump.
- No storage, no constructor arguments, no owner, no proxy, no `selfdestruct`.
- Priya's program becomes: flat fee, `XYCSwap`, Extruction(target = deployed `PoolPriceBandExtruction`, args = build(poolManager, poolKey, bandBps)). The Extruction step must come after the curve, so the registers hold computed amounts.
- The same check runs in `quote()` (STATICCALL) and `swap()` (CALL).

## Out of scope
The hook. Pool creation beyond what the fork test needs (a test may initialise a pool directly on the PoolManager).

## Acceptance
- `test_F03_buildParseRoundTrip`: `parse(build(args)) == args`; `build` output is 88 bytes.
- `test_F03_inBandFills`: pool price equal to Priya's curve price, 1,000 USDC fill through the canonical router succeeds.
- `test_F03_outOfBandReverts`: pool price moved 5% away, `bandBps = 200`, swap reverts with `PoolPriceBandExceeded`.
- `test_F03_quoteRevertsOutOfBand`: same condition reverts in `quote()`.
- `test_F03_bothDirections`: the check holds for USDC->MUMB and MUMB->USDC.
- `test_F03_quoteEqualsSwapSameTx`: in one transaction, quote then swap return identical amounts (D-14).
- `test_F03_wrongPoolTokensReverts`: args naming a pool with different tokens revert with `PoolTokenMismatch`.
- `test_F03_misorderedProgramReverts`: a program with the Extruction step before the curve reverts with `PoolPriceBandNotComputed`.
- `test_F03_noStorage`: the contract has no storage writes (check with `vm.record`/`vm.accesses` across a swap: zero writes to its address).
- Command: `forge test --match-test test_F03 -vvv`

## [VERIFY]
- The Extruction opcode's index in `AquaOpcodes._opcodes()` at v1.0.2 (docs say 32) and how the step's args are framed in the program bytes.
- The exact `IExtruction` / `IStaticExtruction` signatures and the `SwapQuery` / `SwapRegisters` field order in `src/instructions/Extruction.sol` and `src/libs/VM.sol`.
- That after `XYCSwap` the program still continues to the next instruction (it is not terminal), and how the flat-fee instruction wraps the rest of the program. Place the Extruction step where the registers hold the final amounts the taker sees.
- That `StateLibrary.getSlot0` works from a non-hook contract during an unlocked PoolManager session (`extsload` is a public view; confirm in v4-core).
