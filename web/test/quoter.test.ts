// F10: the web copy of searchHint equals scripts/src/quoter.ts on fixed fixtures (same result, same simulated points).
import { test } from "node:test";
import assert from "node:assert/strict";
import { searchHint as scriptsSearch, decodeDelta as scriptsDelta, zeroForOneFor as scriptsZfo, amountInRaw as scriptsRaw } from "../../scripts/src/quoter.ts";
import { searchHint, decodeDelta, zeroForOneFor, amountInRaw } from "../src/lib/quoter.ts";

type Curve = (h: bigint) => bigint | null;
async function both(amountIn: bigint, curve: Curve) {
  const mk = () => {
    const calls: bigint[] = [];
    return { calls, sim: async (h: bigint) => (calls.push(h), curve(h)) };
  };
  const a = mk();
  const b = mk();
  const web = await searchHint(amountIn, a.sim);
  const orig = await scriptsSearch(amountIn, b.sim);
  assert.deepEqual(web, orig);
  assert.deepEqual([...a.calls].sort(), [...b.calls].sort(), "same simulated points");
  return web;
}

test("test_F10_searchHintEqualsScripts_concave", async () => {
  const r = await both(1_000_000_000n, (h) => 10n ** 15n - (h - 550_000_000n) ** 2n);
  assert.equal(r.hint, 550_000_000n);
});
test("test_F10_searchHintEqualsScripts_revertingPoints", async () => {
  const r = await both(6000n, (h) => (h >= 3000n && h <= 3300n ? null : 10n ** 12n - (h - 4000n) ** 2n));
  assert.ok(r.hint !== 0n);
});
test("test_F10_searchHintEqualsScripts_tiesGoToSmallerHint", async () => {
  const r = await both(1000n, () => 777n);
  assert.equal(r.hint, 0n);
});
test("test_F10_searchHintEqualsScripts_onlyHintZeroUsable", async () => {
  const r = await both(1000n, (h) => (h === 0n ? 5n : null));
  assert.equal(r.hint, 0n);
});
test("test_F10_searchHintHintZeroRevertsThrows", async () => {
  await assert.rejects(searchHint(1000n, async (h) => (h === 0n ? null : 1n)), /hint 0\) reverted/);
  await assert.rejects(searchHint(0n, async () => 1n), /positive/);
});
test("test_F10_helpersEqualScripts", () => {
  const usdc = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  const mumb = "0xC717f7Ae74836d48d64CBb9349FFa49Ad3E1241A";
  for (const dir of ["usdc-to-mumb", "mumb-to-usdc"] as const) {
    assert.equal(zeroForOneFor(dir, usdc, mumb), scriptsZfo(dir, usdc, mumb));
    assert.equal(zeroForOneFor(dir, mumb, usdc), scriptsZfo(dir, mumb, usdc));
    assert.equal(amountInRaw("1000.5", dir), scriptsRaw("1000.5", dir));
  }
  assert.equal(zeroForOneFor("usdc-to-mumb", usdc, mumb), true, "USDC is currency0 in our deployment");
  const packed = (5n << 128n) | 7n;
  assert.equal(decodeDelta(packed, true), scriptsDelta(packed, true));
  assert.equal(decodeDelta(packed, false), scriptsDelta(packed, false));
  assert.equal(decodeDelta((1n << 256n) - 1n, true), -1n);
});
