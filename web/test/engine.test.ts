// F10 engine: JSON round trips, ordering, determinism.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { runFromJson, runToJson, toRunFile, stringifyRunFile } from "../src/lib/engine.ts";
import type { QuotePoint, RunFile } from "../src/lib/types.ts";

const raw = readFileSync(new URL("./fixtures/run-1000.json", import.meta.url), "utf8");
const fx = JSON.parse(raw) as RunFile;

test("test_F10_runJsonRoundTrip", () => {
  const rec = runFromJson(fx.split, "confluence");
  assert.equal(rec.mumbOut, 991549823315669231761n);
  assert.equal(rec.fill?.amountIn, 550_000_000n);
  assert.equal(rec.before.sqrtPrice, 79228162514264337593543950336000000n);
  assert.deepEqual(runToJson(rec), fx.split);
  const pool = runFromJson(fx.poolOnly, "pool only");
  assert.equal(pool.fill, undefined);
  assert.deepEqual(runToJson(pool), fx.poolOnly);
});

test("test_F10_runFileIsByteIdenticalWhateverThePointOrder", () => {
  const pts: QuotePoint[] = [0n, 100n, 550n, 1000n].map((h) => ({ hint: h.toString(), out: h === 100n ? null : (1000n + h).toString() }));
  const mk = (p: QuotePoint[]) =>
    stringifyRunFile(
      toRunFile({
        block: 26349400,
        dir: "usdc-to-mumb",
        amountIn: 1_000_000_000n,
        points: p,
        hint: 550_000_000n,
        aquaShare: 0.55,
        poolOnly: runFromJson(fx.poolOnly, "pool only"),
        split: runFromJson(fx.split, "confluence"),
      }),
    );
  const a = mk(pts);
  const b = mk([...pts].reverse());
  assert.equal(a, b);
  assert.ok(a.endsWith("\n"));
  const parsed = JSON.parse(a) as RunFile;
  assert.deepEqual(parsed.quote.points.map((p) => p.hint), ["0", "100", "550", "1000"]);
  assert.equal(parsed.split.mumbOut, "991549823315669231761");
  assert.equal(parsed.schema, 1);
  assert.ok(!/timestamp|hash|snapshot/i.test(a));
});
