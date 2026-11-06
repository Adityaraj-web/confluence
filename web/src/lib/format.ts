// Display and price maths. Copies of scripts/src/demo.ts @eb8522b (percent, avgPrice, priceMovePercent) plus
// usdcPerMumb, which the CLI does not have. All inputs are bigint; strings come out.
import { formatUnits } from "viem";
import { MUMB_DECIMALS, USDC_DECIMALS } from "./constants.ts";

/** `diff / base` as a percentage with two decimals, rounded down: "3.10%". */
export function percent(diff: bigint, base: bigint): string {
  const hundredths = (diff * 10_000n) / base;
  return `${hundredths / 100n}.${(hundredths % 100n).toString().padStart(2, "0")}%`;
}

/** The pool's slot0 price (sqrtPrice squared) moved by this much, as a percentage of the price before: "2.40%". */
export function priceMovePercent(sqrtBefore: bigint, sqrtAfter: bigint): string {
  const before = sqrtBefore * sqrtBefore;
  const after = sqrtAfter * sqrtAfter;
  return percent(after > before ? after - before : before - after, before);
}

/** Price of one output token in input tokens, six decimals, rounded down. */
export function avgPrice(inAmount: bigint, outAmount: bigint, inDecimals: number, outDecimals: number): string {
  if (outAmount === 0n) throw new Error("avgPrice: the output amount is zero");
  const scaled = (inAmount * 10n ** BigInt(outDecimals) * 1_000_000n) / (outAmount * 10n ** BigInt(inDecimals));
  return `${scaled / 1_000_000n}.${(scaled % 1_000_000n).toString().padStart(6, "0")}`;
}

const Q192 = 1n << 192n;

/**
 * USDC per 1 MUMB from slot0 sqrtPriceX96, six decimals, rounded down.
 * slot0 price p = s^2 / 2^192 is token1 per token0 in raw units.
 *  - USDC is currency0: p = MUMBwei per USDC unit, so USDC/MUMB = 10^12 / p, scaled by 10^6: 2^192 * 10^18 / s^2.
 *  - USDC is currency1: p = USDC units per MUMBwei, so USDC/MUMB = 10^12 * p, scaled by 10^6: s^2 * 10^18 / 2^192.
 * Multiplies before dividing, so the only loss is the final floor.
 */
export function usdcPerMumb(sqrtPriceX96: bigint, usdcIsCurrency0: boolean): string {
  if (sqrtPriceX96 === 0n) throw new Error("usdcPerMumb: sqrtPrice is zero");
  const s2 = sqrtPriceX96 * sqrtPriceX96;
  const scaled = usdcIsCurrency0 ? (Q192 * 10n ** 18n) / s2 : (s2 * 10n ** 18n) / Q192;
  return `${scaled / 1_000_000n}.${(scaled % 1_000_000n).toString().padStart(6, "0")}`;
}

/** Split minus pool-only: the MUMB gain (unsigned text) and its size in basis points with a sign ("+67.16"). */
export function formatGain(poolOnlyOut: bigint, splitOut: bigint): { mumb: string; bps: string; sign: "+" | "-" } {
  const gain = splitOut - poolOnlyOut;
  const abs = gain < 0n ? -gain : gain;
  const hundredthsBps = (abs * 1_000_000n) / poolOnlyOut;
  const sign = gain < 0n ? "-" : "+";
  return {
    mumb: formatUnits(abs, MUMB_DECIMALS),
    bps: `${sign}${hundredthsBps / 100n}.${(hundredthsBps % 100n).toString().padStart(2, "0")}`,
    sign,
  };
}

export const fmtUsdc = (v: bigint) => formatUnits(v, USDC_DECIMALS);
export const fmtMumb = (v: bigint) => formatUnits(v, MUMB_DECIMALS);

/** Rounds a decimal string down to `dp` places and groups the integer part: "984.934194542570551127" -> "984.934". */
export function trunc(decimal: string, dp: number): string {
  const [i = "0", f = ""] = decimal.split(".");
  const neg = i.startsWith("-");
  const digits = neg ? i.slice(1) : i;
  const grouped = digits.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const frac = f.padEnd(dp, "0").slice(0, dp);
  return `${neg ? "-" : ""}${grouped}${dp > 0 ? `.${frac}` : ""}`;
}

/** Signed delta text for a before/after pair: "+0.550" / "-545.360" / "0". */
export function signedDelta(before: bigint, after: bigint, decimals: number, dp: number): string {
  const d = after - before;
  if (d === 0n) return "0";
  const text = trunc(formatUnits(d < 0n ? -d : d, decimals), dp);
  return `${d < 0n ? "-" : "+"}${text}`;
}
