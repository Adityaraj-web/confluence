// F10 live integration tests. They need the anvil fork at the deploy state (a fresh `deploy`, or `demo:reset`).
// Run: pnpm --dir web run test:int   (serial: a revert in one test discards the snapshots another holds)
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createPublicClient, http, type Hex } from "viem";
import { createLiveSource, type LiveSource } from "../src/lib/sources/live.ts";
import { rpc, snapFromJson } from "../src/lib/engine.ts";
import { amountInRaw } from "../src/lib/quoter.ts";
import { priceMovePercent } from "../src/lib/format.ts";
import type { DeploymentJson, GuardFile, RunFile } from "../src/lib/types.ts";

const url = (p: string) => new URL(p, import.meta.url);
const d = JSON.parse(readFileSync(url("../../deployments/local.json"), "utf8")) as DeploymentJson;
const fx = JSON.parse(readFileSync(url("./fixtures/run-1000.json"), "utf8")) as RunFile;
const RPC = process.env.ANVIL_RPC_URL ?? "http://127.0.0.1:8545";
const KEY = process.env.TRADER_PRIVATE_KEY as Hex;
const expectedBefore = snapFromJson(fx.poolOnly.before);
const pub = createPublicClient({ transport: http(RPC) });
const toasts: string[] = [];

async function open(over: Partial<Parameters<typeof createLiveSource>[0]> = {}): Promise<LiveSource> {
  const r = await createLiveSource({ rpcUrl: RPC, deployment: d, traderKey: KEY, expectedBefore, onToast: (m) => toasts.push(m), ...over });
  if ("refused" in r) throw new Error(`refused: ${r.refused}`);
  return r.source;
}
const m1000 = amountInRaw("1000", "usdc-to-mumb");
const cli = (cmd: string) =>
  execFileSync("pnpm", ["--dir", "../scripts", "run", cmd], { encoding: "utf8", cwd: new URL("..", import.meta.url) });

test("test_F10_live_refusesUnreachableRpc", async () => {
  const r = await createLiveSource({ rpcUrl: "http://127.0.0.1:9", deployment: d, traderKey: KEY });
  assert.ok("refused" in r && /cannot reach an RPC at http:\/\/127\.0\.0\.1:9/.test(r.refused), JSON.stringify(r));
});

test("test_F10_live_refusesWrongKey", async () => {
  const r = await createLiveSource({ rpcUrl: RPC, deployment: d, traderKey: process.env.DEPLOYER_PRIVATE_KEY as Hex });
  assert.ok("refused" in r && /deployment's trader/.test(r.refused), JSON.stringify(r));
});

test("test_F10_live_startsAtTheDeployState", async () => {
  const s = await open();
  assert.equal(s.deployState(), "ok");
  const h = await s.header();
  assert.equal(h.forkBlock, 26349400);
  assert.equal(h.usdcPerMumb, "1.000000");
  assert.equal(h.pool.usdcIsCurrency0, true);
  assert.equal(h.pool.bandBps, 200);
});

test("test_F10_live_snapshotIdProbe", async () => {
  // Are anvil snapshot ids reused? snapshot a, b; revert a; snapshot c. Reported in D-25. No chain state changes.
  const a = await rpc<Hex>(pub, "evm_snapshot");
  const b = await rpc<Hex>(pub, "evm_snapshot");
  const okA = await rpc<boolean>(pub, "evm_revert", [a]);
  const c = await rpc<Hex>(pub, "evm_snapshot");
  const okB = await rpc<boolean>(pub, "evm_revert", [b]);
  const okC = await rpc<boolean>(pub, "evm_revert", [c]);
  console.log(`PROBE a=${a} b=${b} revert(a)=${okA} c=${c} revert(b after revert(a))=${okB} revert(c)=${okC} reused=${c === a || c === b}`);
  assert.equal(okA, true);
});

test("test_F10_live_compare1000EqualsCliAndLeavesDeployState", async () => {
  const s = await open();
  const points: unknown[] = [];
  const f = await s.compare({ dir: "usdc-to-mumb", amountIn: m1000 }, (p) => points.push(p));
  assert.equal(f.poolOnly.mumbOut, "984934194542570551127");
  assert.equal(f.split.mumbOut, "991549823315669231761");
  assert.equal(f.quote.hint, "550000000");
  assert.equal(f.quote.aquaShare, 0.55);
  assert.deepEqual(f.poolOnly, fx.poolOnly);
  assert.deepEqual(f.split, fx.split);
  assert.equal(f.quote.points.length, 16);
  assert.equal(points.length, 16);
  assert.deepEqual(f.quote.points.map((p) => BigInt(p.hint)), [...f.quote.points.map((p) => BigInt(p.hint))].sort((x, y) => (x < y ? -1 : 1)));
  const h = await s.header();
  assert.equal(h.sqrtPrice, fx.poolOnly.before.sqrtPrice, "chain is back at the deploy state");
  assert.equal(s.busy(), false);
});

test("test_F10_live_compare2000EqualsCli", async () => {
  const s = await open();
  const f = await s.compare({ dir: "usdc-to-mumb", amountIn: amountInRaw("2000", "usdc-to-mumb") });
  assert.equal(f.poolOnly.mumbOut, "1946313880914421030318");
  assert.equal(f.split.mumbOut, "1972317821361470963008");
  assert.equal(f.quote.hint, "1100000000");
  const b = BigInt(f.poolOnly.before.sqrtPrice);
  assert.equal(priceMovePercent(b, BigInt(f.poolOnly.after.sqrtPrice)), "4.72%");
  assert.equal(priceMovePercent(b, BigInt(f.split.after.sqrtPrice)), "2.16%");
});

test("test_F10_live_guardNumbers", async () => {
  const s = await open();
  const g: GuardFile = await s.guard(m1000);
  assert.equal(g.hint, "550000000");
  assert.equal(g.hinted.mumbOut, "949918037701570887505");
  assert.equal(g.move.out, "1468515224108057815578");
  assert.match(g.hinted.skipReason, /^PoolPriceBandExceeded\(.*fill price 3\.14% off the pool price, band 2\.00%$/);
  assert.equal(priceMovePercent(BigInt(g.move.sqrtBefore), BigInt(g.move.sqrtAfter)), "3.57%");
  assert.equal(g.hinted.fill, undefined);
});

test("test_F10_live_busyLockRejectsASecondAction", async () => {
  const s = await open();
  const first = s.compare({ dir: "usdc-to-mumb", amountIn: m1000 });
  assert.equal(s.busy(), true);
  await assert.rejects(s.compare({ dir: "usdc-to-mumb", amountIn: m1000 }), /busy/);
  await assert.rejects(s.guard(m1000), /busy/);
  await first;
  assert.equal(s.busy(), false);
});

test("test_F10_live_recoversWhenTheCliConsumedOurSnapshot", async () => {
  const s = await open();
  const s0 = await rpc<Hex>(pub, "evm_snapshot"); // older than the web's W, like the CLI's saved id
  await s.compare({ dir: "usdc-to-mumb", amountIn: m1000 });
  toasts.length = 0;
  assert.equal(await rpc<boolean>(pub, "evm_revert", [s0]), true); // drops s0 and every later id, W included
  const f = await s.compare({ dir: "usdc-to-mumb", amountIn: m1000 });
  assert.equal(f.split.mumbOut, fx.split.mumbOut);
  assert.ok(toasts.some((t) => /re-synced/.test(t)), `a quiet toast, got ${JSON.stringify(toasts)}`);
  assert.equal(s.deployState(), "ok");
});

test("test_F10_live_coexistsWithTheCli", async () => {
  const lastDemo = () => readFileSync(url("../../deployments/last-demo.json"), "utf8");
  const cli1 = cli("demo");
  const cli1File = lastDemo();
  const s = await open();
  const a = await s.compare({ dir: "usdc-to-mumb", amountIn: m1000 });
  const cli2 = cli("demo");
  assert.equal(cli2, cli1, "CLI output after a web run equals the first CLI output");
  assert.equal(lastDemo(), cli1File);
  toasts.length = 0;
  const b = await s.compare({ dir: "usdc-to-mumb", amountIn: m1000 });
  assert.deepEqual(b, a, "web recovers its snapshot and gives the same numbers");
  const cli3 = cli("demo");
  assert.equal(cli3, cli1, "the web did not consume the CLI's saved snapshot");
  console.log(`COEXIST toasts after the CLI run: ${JSON.stringify(toasts)}`);
});
