---
paths:
  - "scripts/**/*.ts"
  - "web/**/*.{ts,tsx}"
---

# TypeScript rules

- TypeScript strict mode. viem for all chain access; no ethers.
- ABIs come from forge artifacts (`contracts/out/`), never hand-written.
- Addresses come from `deployments/local.json` or `.env`, never inlined.
- 1inch SDKs at the exact versions in DECISIONS D-04. Build programs with `AquaProgramBuilder`, which rejects opcodes the canonical router does not have. A TS-built order must encode to the same bytes as `StrategyLib` for the same parameters.
- Amounts are `bigint` in base units everywhere; format to decimals only for display (USDC 6, MUMB 18).
- Every script prints what it did and exits non-zero on failure.
- Web: functional React components, Tailwind CSS, no component library beyond what F10 needs. Large, high-contrast type for the projector.
- Before calling a feature done: `tsc --noEmit` passes for the folder you changed.
