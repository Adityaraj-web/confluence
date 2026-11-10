# V2-11 Gas budget

- Owner: Adityaraj
- Depends on: V2-07 to V2-09
- Branch: `v2/11-gas`
- Architecture: ARCHITECTURE-v2 section 5
- Decisions: one entry per constant fixed

## Goal
Measured, defended values for every constant, and a swap that never reverts where pool-only would pass.

## Files
- `.gas-snapshot`, `docs/GAS.md`, constants in `contracts/src/ConfluenceHook.sol`, `contracts/test/gas/V211Gas.t.sol`, CI workflow

## Behaviour
- `forge snapshot` scenarios: 0-3 legs × 0/4/8 tick crossings × exact in/out.
- Repeat D-20's gas-limit sweep for multi-leg swaps; set `GAS_RESERVE`, `LEG_GAS_CAP`.
- Fix `MAX_STRATEGIES`, `MAX_LEGS`, `MAX_TICK_RANGES`, `MIN_LEG_BPS`, `EMA_HALF_LIFE`.
- `GAS.md`: overhead vs pool-only per scenario; price gain at 500/1,000/2,000/5,000 USDC; break-even gas price on Unichain and mainnet.
- CI fails on gas regression > 5% (`forge snapshot --check --tolerance 5`).

## Acceptance
- `test_V211_neverRevertsWherePoolOnlyPasses`: sweep tx gas limits; every limit that lets a pool-only swap pass also passes the hooked swap.
- `test_V211_worstCaseBelowCeiling`.
- `.gas-snapshot` committed; GAS.md written from measured numbers only.
