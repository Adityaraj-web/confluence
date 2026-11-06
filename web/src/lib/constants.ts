// Duplicated from scripts/ (D-24, D-25): scripts/src/config.ts imports node:fs at load, so a browser cannot import it.
// Sources: config.ts @74ed8de (SWAP_GAS_LIMIT, decimals), demo.ts @eb8522b (price limits, DEMO_AMOUNT, GUARD_MOVE_AMOUNT).

/** Gas limit for every swap send and every simulation of one (D-20). */
export const SWAP_GAS_LIMIT = 1_500_000n;
export const USDC_DECIMALS = 6;
export const MUMB_DECIMALS = 18;

// TickMath.MIN_SQRT_PRICE + 1 and MAX_SQRT_PRICE - 1: no price limit in practice.
export const MIN_PRICE_LIMIT = 4295128740n;
export const MAX_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341n;

export const DEMO_AMOUNT = "1000";
export const GUARD_MOVE_AMOUNT = "1500";
