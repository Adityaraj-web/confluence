// Copy of scripts/src/demo.ts @eb8522b guardChecks. What the guard must show for the hinted swap after the pool price moved.
import { decodeSkipReason } from "./decode.ts";
import type { RunRecord } from "./types.ts";

/** Pure: [passed, what] pairs. */
export function guardChecks(hinted: RunRecord, amountIn: bigint): [boolean, string][] {
  const priyaUntouched =
    hinted.before.priyaMumb === hinted.after.priyaMumb &&
    hinted.before.priyaUsdc === hinted.after.priyaUsdc &&
    hinted.before.aquaMumb === hinted.after.aquaMumb &&
    hinted.before.aquaUsdc === hinted.after.aquaUsdc;
  return [
    [hinted.skipped !== undefined, "AquaSkipped was emitted"],
    [hinted.fill === undefined, "no AquaFill: Priya was not filled"],
    [
      hinted.skipped !== undefined && decodeSkipReason(hinted.skipped).startsWith("PoolPriceBandExceeded("),
      "the skip reason is PoolPriceBandExceeded (the guard, not some other skip)",
    ],
    [hinted.usdcIn === amountIn && hinted.mumbOut > 0n, "the trader paid the swap amount and received MUMB"],
    [priyaUntouched, "Priya's wallet and Aqua balances are untouched"],
  ];
}
