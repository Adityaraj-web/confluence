# F01 Fork test base and MockMUMB

- Owner: T1
- Depends on: F00
- Architecture: sections 1, 2 (steps 1-2), 4

## Goal
A shared test base that every fork test extends, so setup is written once.

## Files
- `contracts/src/mocks/MockMUMB.sol`: OpenZeppelin ERC-20, name "Mumbai Token", symbol "MUMB", 18 decimals, public `mint` restricted to the deployer.
- `contracts/test/base/ForkBase.t.sol`
- `contracts/test/fork/F01ForkBase.t.sol`

## Behaviour (ForkBase)
- Creates and selects a fork of `MAINNET_RPC_URL` at `FORK_BLOCK`.
- Named actors: `priya`, `trader`, `deployer` (`makeAddr`).
- Constants for Aqua, the canonical AquaSwapVMRouter, USDC, WETH and PoolManager addresses (from ARCHITECTURE.md).
- Deploys MockMUMB; mints 1,000,000 MUMB to Priya and 10,000 to the trader.
- Funds with `deal`: 1,000,000 USDC to Priya, 100,000 USDC to the trader.
- Helper `balances(address)` returning MUMB and USDC balances, used by later tests.
- Helper `sortedPair()` returning (currency0, currency1) for MUMB and USDC by address.

## Out of scope
Pool creation, Aqua strategies.

## Acceptance
- `test_F01_officialContractsExist`: code size > 0 at the Aqua, AquaSwapVMRouter and PoolManager addresses.
- `test_F01_routerBoundToAqua`: the router's `AQUA()` returns the Aqua registry address; its `eip712Domain()` version is `1.0.2`.
- `test_F01_actorsFunded`: balances match the amounts above.
- `test_F01_sortedPair`: currency0 < currency1.
- Command: `forge test --match-path test/fork/F01ForkBase.t.sol -vvv`
