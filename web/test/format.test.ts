// F10 format/price tests. The web copies must equal the scripts' originals on fixed fixtures.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { avgPrice as scriptsAvgPrice, priceMovePercent as scriptsMove } from "../../scripts/src/demo.ts";
import { avgPrice, formatGain, priceMovePercent, usdcPerMumb } from "../src/lib/format.ts";
import type { RunFile } from "../src/lib/types.ts";

const fx = JSON.parse(readFileSync(new URL("./fixtures/run-1000.json", import.meta.url), "utf8")) as RunFile;
const big = (s: string) => BigInt(s);

test("test_F10_avgPriceEqualsScripts", () => {
  const p = avgPrice(big(fx.poolOnly.usdcIn), big(fx.poolOnly.mumbOut), 6, 18);
  const s = avgPrice(big(fx.split.usdcIn), big(fx.split.mumbOut), 6, 18);
  assert.equal(p, "1.015296");
  assert.equal(s, "1.008522");
  assert.equal(p, scriptsAvgPrice(big(fx.poolOnly.usdcIn), big(fx.poolOnly.mumbOut), 6, 18));
  assert.equal(s, scriptsAvgPrice(big(fx.split.usdcIn), big(fx.split.mumbOut), 6, 18));
  assert.throws(() => avgPrice(1n, 0n, 6, 18), /zero/);
});

test("test_F10_priceMoveEqualsScripts", () => {
  const b = big(fx.poolOnly.before.sqrtPrice);
  assert.equal(priceMovePercent(b, big(fx.poolOnly.after.sqrtPrice)), "2.40%");
  assert.equal(priceMovePercent(b, big(fx.split.after.sqrtPrice)), "1.09%");
  assert.equal(priceMovePercent(b, big(fx.poolOnly.after.sqrtPrice)), scriptsMove(b, big(fx.poolOnly.after.sqrtPrice)));
  assert.equal(priceMovePercent(b, big(fx.split.after.sqrtPrice)), scriptsMove(b, big(fx.split.after.sqrtPrice)));
});

test("test_F10_gainMatchesCli", () => {
  const g = formatGain(big(fx.poolOnly.mumbOut), big(fx.split.mumbOut));
  assert.equal(g.mumb, "6.615628773098680634");
  assert.equal(g.bps, "+67.16");
});

test("test_F10_usdcPerMumb_anchors", () => {
  // USDC is currency0 (our deployment): sqrtPrice 2^96 * 1e6 is exactly 1 USDC per MUMB.
  assert.equal(usdcPerMumb(big(fx.poolOnly.before.sqrtPrice), true), "1.000000");
  // USDC is currency1: sqrtPrice floor(2^96 / 1e6) is 1 USDC per MUMB less 1.2e-24 relative, so rounding down gives 0.999999.
  assert.equal(usdcPerMumb(2n ** 96n / 10n ** 6n, false), "0.999999");
});

test("test_F10_usdcPerMumb_poolOnlyAfterCrossCheck", () => {
  const s0 = big(fx.poolOnly.before.sqrtPrice);
  const s1 = big(fx.poolOnly.after.sqrtPrice);
  const got = usdcPerMumb(s1, true);
  assert.equal(got, "1.024650");
  // Independent float check: price ratio squared, floored to 6 decimals.
  const r = Number(s0) / Number(s1);
  assert.equal(Math.floor(r * r * 1e6), 1_024_650);
  // Buying MUMB with USDC (USDC is currency0) lowers sqrtPrice and raises USDC per MUMB.
  assert.ok(s1 < s0 && big(got.replace(".", "")) > 1_000_000n);
  assert.throws(() => usdcPerMumb(0n, true), /zero/);
});
