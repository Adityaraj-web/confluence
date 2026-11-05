# F00 Repo scaffold and dependencies

- Owner: Both (one laptop, hour 0-1)
- Depends on: none
- Architecture: sections 1 and 2

## Goal
A repo where v4 and the swap-vm v1.0.2 interfaces and types compile together, fork tests can run, and the scripts and web folders exist. We deploy no SwapVM code (D-13); we only import its interfaces and types.

## Files
- `contracts/foundry.toml`, `contracts/remappings.txt`
- `contracts/lib/` via `forge install`: forge-std, v4-core, v4-periphery, 1inch/swap-vm at the v1.0.2 tag (D-04), 1inch/aqua at the version swap-vm v1.0.2 depends on, OpenZeppelin contracts
- `.env.example` (MAINNET_RPC_URL, FORK_BLOCK, anvil test keys for PRIYA, TRADER, DEPLOYER). The RPC must serve archive state, because fork tests pin an older block.
- `.gitignore` (`.env`, `out/`, `cache/`, `node_modules/`)
- `scripts/package.json`, `scripts/tsconfig.json` (TypeScript, viem, tsx, `@1inch/swap-vm-sdk@0.4.0`, `@1inch/aqua-sdk@0.3.0`, exact versions)
- `web/` created with Vite's React + TypeScript template
- `LICENSE` (MIT) at the root
- `contracts/test/unit/Smoke.t.sol`

## Behaviour
- Solidity 0.8.30. Enable via-IR only if importing swap-vm types needs it; if it breaks v4, use a profile and record it in DECISIONS.
- Remappings resolve imports used by v4 (`v4-core/`, `@uniswap/v4-core/` if needed), SwapVM and Aqua.
- If swap-vm needs packages that forge cannot fetch (it builds with Hardhat), vendor only the interface and library files we import, unmodified, and note it in DECISIONS.
- Record in D-04 the exact tag or commit `forge install` resolved for swap-vm and aqua.

## Out of scope
Any project logic. No contracts beyond the smoke test.

## Acceptance
- `forge build` succeeds from `contracts/` with v4's PoolManager interface and swap-vm v1.0.2's `IExtruction`, `SwapQuery` and `SwapRegisters` compiled.
- `test_F00_smoke` imports one v4-core type and `IExtruction` from swap-vm and passes.
- `pnpm --dir scripts tsc --noEmit` passes; `pnpm --dir web build` passes.
- CLAUDE.md "Commands" section matches the real commands.

## [VERIFY]
- Does the swap-vm v1.0.2 source we import compile under Foundry with the same remappings as v4? If not, record the workaround.
- The v1.0.2 tag name exists as expected (`git ls-remote --tags https://github.com/1inch/swap-vm`).
