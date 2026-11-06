// F10 format/price tests. The web copies must equal the scripts' originals on fixed fixtures.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { avgPrice as scriptsAvgPrice, priceMovePercent as scriptsMove } from "../../scripts/src/demo.ts";
import { avgPrice, formatGain, group, priceMovePercent, roundTo, usdcPerMumb } from "../src/lib/format.ts";
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

test("test_F10_roundToNearestForDisplay", () => {
  // The wireframe's numbers: 984.934, 991.550 (991.5498...), +6.616 (6.6156...), 949.918.
  assert.equal(roundTo(984934194542570551127n, 18, 3), "984.934");
  assert.equal(roundTo(991549823315669231761n, 18, 3), "991.550");
  assert.equal(roundTo(6615628773098680634n, 18, 3), "6.616");
  assert.equal(roundTo(949918037701570887505n, 18, 3), "949.918");
  assert.equal(roundTo(1972317821361470963008n, 18, 3), "1,972.318");
  assert.equal(roundTo(999999600000000000000n, 18, 3), "1,000.000", "carries into the integer part");
  assert.equal(roundTo(500_000n, 6, 0), "1", "half rounds up");
  assert.equal(roundTo(0n, 18, 3), "0.000");
  assert.equal(roundTo(-1500000000000000n, 18, 3), "-0.002");
  assert.equal(roundTo(1_234_567_000n, 6, 0), "1,235");
});

test("test_F10_groupKeepsTheFraction", () => {
  assert.equal(group("550"), "550");
  assert.equal(group("1000"), "1,000");
  assert.equal(group("1234567.25"), "1,234,567.25");
  assert.equal(group("-1234.5"), "-1,234.5");
});
