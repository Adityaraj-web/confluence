# F02 Aqua baseline: ship and swap on the canonical router

- Owner: T2
- Depends on: F00, F01
- Architecture: sections 1, 2 (step 6), 3 (steps 5-7)
- Decisions: D-02, D-04, D-13

## Goal
Prove, before touching v4, that we can ship Priya's strategy to Aqua on 1inch's deployed `AquaSwapVMRouter` and fill it from a contract taker with the pay-by-transfer setting. This de-risks the hour-8 gate. We deploy no router.

## Files
- `contracts/test/fork/F02AquaBaseline.t.sol`
- `contracts/test/base/StrategyLib.sol` (test helper that builds Priya's program and order for the canonical router's opcode set)
- `contracts/test/base/TakerHelper.sol` (stand-in for the hook: approves, calls `swap`, holds nothing afterwards)
- Interfaces for the router and Aqua come from `contracts/lib/` (swap-vm v1.0.2, aqua). Write a local interface only if the lib's cannot be imported; note it in DECISIONS.

## Behaviour
- Router = the canonical address from ARCHITECTURE section 1, used as deployed.
- Priya's program: a flat input fee (0.30%) then `XYCSwap`, in Aqua mode, using only opcodes in the canonical router's set. Take opcode indices from `AquaOpcodes._opcodes()` in the v1.0.2 source.
- Priya approves MUMB and USDC to Aqua, then calls `aqua.ship(app = canonical router, strategy = encoded order, tokens = [MUMB, USDC], amounts = [100,000 MUMB, 100,000 USDC])`.
- `TakerHelper` calls the router's 5-argument `swap(order, tokenIn, tokenOut, amount, takerTraitsAndData)` with `useTransferFromAndAquaPush = true`, exact input, paying USDC for MUMB.

## Out of scope
The band extruction (F03), v4, the hook.

## Acceptance
- `test_F02_shipCreatesVirtualBalances`: `aqua.safeBalances` for (Priya, canonical router, strategy hash) equal the shipped amounts; Priya's wallet unchanged.
- `test_F02_takerContractSwap`: the taker helper pays 1,000 USDC and receives MUMB > 0; Priya's wallet MUMB down by the same amount; Priya's Aqua USDC virtual balance up by 1,000; the helper holds no USDC or MUMB afterwards.
- `test_F02_quoteMatchesSwap`: the router's quote equals the executed amounts.
- `test_F02_noTxOriginRequirement`: the swap succeeds when `tx.origin` is not the taker contract.
- Command: `forge test --match-path test/fork/F02AquaBaseline.t.sol -vvv`

## [VERIFY] (record answers in D-02 and D-04)
- Which contract calls `transferFrom` on the taker under `useTransferFromAndAquaPush` in v1.0.2, so the hook knows whom to approve. Confirm the trait's exact name.
- The exact `swap` and `quote` signatures and how `takerTraitsAndData` is packed at v1.0.2.
- Whether the strategy passed to `ship` is the full encoded order, and how the strategy hash is computed.
- The flat-fee opcode's name and index in the Aqua opcode set; whether the fee instruction runs the rest of the program inside itself (this affects where F03's Extruction step sits).
