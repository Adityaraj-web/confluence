// F10 record: runs the engine's live source against anvil and writes web/public/runs/*.json (the replay data).
// Run: pnpm --dir web run record   (anvil at the deploy state; leaves it there; two runs are byte-identical)
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { Hex } from "viem";
import { formatGain, fmtMumb, priceMovePercent } from "../src/lib/format.ts";
import { snapFromJson, stringifyRunFile } from "../src/lib/engine.ts";
import { amountInRaw } from "../src/lib/quoter.ts";
import { createLiveSource } from "../src/lib/sources/live.ts";
import type { DeploymentJson, Direction, GuardFile, RunFile, RunsIndex, Snap, SnapJson } from "../src/lib/types.ts";

const here = (p: string) => fileURLToPath(new URL(p, import.meta.url));
const OUT = here("../public/runs/");
const AMOUNTS = ["500", "1000", "2000"] as const;
const GUARD_AMOUNT = "1000";
const DIR: Direction = "usdc-to-mumb";

function fail(msg: string): never {
  console.error(`record: ${msg}`);
  process.exit(1);
}

/** The deploy state to check the chain against (gap 2): the committed 1,000 USDC run, else the CLI's last-demo.json, else nothing. */
function expectedBefore(): Snap | undefined {
  for (const [path, pick] of [
    [`${OUT}usdc-to-mumb-1000.json`, (j: RunFile) => j.poolOnly.before],
    [here("../../deployments/last-demo.json"), (j: { poolOnly: { before: SnapJson } }) => j.poolOnly.before],
  ] as const) {
    if (existsSync(path)) return snapFromJson((pick as (j: never) => SnapJson)(JSON.parse(readFileSync(path, "utf8")) as never));
  }
  console.warn("record: no recorded run and no last-demo.json: the deploy-state check is skipped");
  return undefined;
}

async function main(): Promise<void> {
  const localPath = here("../../deployments/local.json");
  if (!existsSync(localPath)) fail(`${localPath} not found: run \`pnpm --dir scripts run deploy\` on a fresh fork`);
  const deployment = JSON.parse(readFileSync(localPath, "utf8")) as DeploymentJson;
  const traderKey = process.env.TRADER_PRIVATE_KEY as Hex | undefined;
  if (!traderKey) fail("TRADER_PRIVATE_KEY is missing (it is in .env.example)");

  const r = await createLiveSource({
    rpcUrl: process.env.ANVIL_RPC_URL ?? "http://127.0.0.1:8545",
    deployment,
    traderKey,
    expectedBefore: expectedBefore(),
    onToast: (m) => console.log(`note: ${m}`),
  });
  if ("refused" in r) fail(`live mode refused: ${r.refused}`);
  const src = r.source;
  if (src.deployState() === "mismatch") {
    fail("the chain is not at the deploy state: run `pnpm --dir scripts run demo:reset` (or `deploy` on a fresh fork)");
  }

  mkdirSync(OUT, { recursive: true });
  const header = await src.header();
  const runs: RunsIndex["runs"] = [];
  const write = (name: string, body: unknown) => {
    writeFileSync(`${OUT}${name}`, stringifyRunFile(body));
    console.log(`wrote web/public/runs/${name}`);
  };

  for (const amount of AMOUNTS) {
    const f = await src.compare({ dir: DIR, amountIn: amountInRaw(amount, DIR) });
    const gain = formatGain(BigInt(f.poolOnly.mumbOut), BigInt(f.split.mumbOut));
    const b = BigInt(f.poolOnly.before.sqrtPrice);
    console.log(
      `${amount} USDC: pool-only ${fmtMumb(BigInt(f.poolOnly.mumbOut))} MUMB, CONFLUENCE ${fmtMumb(BigInt(f.split.mumbOut))} MUMB, ` +
        `gain ${gain.sign}${gain.mumb} (${gain.bps} bps), hint ${f.quote.hint} (${(f.quote.aquaShare * 100).toFixed(2)}%), ` +
        `price move ${priceMovePercent(b, BigInt(f.poolOnly.after.sqrtPrice))} vs ${priceMovePercent(b, BigInt(f.split.after.sqrtPrice))}`,
    );
    const file = `usdc-to-mumb-${amount}.json`;
    write(file, f);
    runs.push({ file, dir: DIR, amount });
  }

  const g: GuardFile = await src.guard(amountInRaw(GUARD_AMOUNT, DIR));
  console.log(`guard ${GUARD_AMOUNT} USDC: ${fmtMumb(BigInt(g.hinted.mumbOut))} MUMB out, ${g.hinted.skipReason}`);
  const guardFile = `guard-${GUARD_AMOUNT}.json`;
  write(guardFile, g);

  const index: RunsIndex = {
    schema: 1,
    fork: { block: header.forkBlock },
    pool: header.pool,
    addresses: {
      usdc: deployment.usdc,
      mumb: deployment.mumb,
      hook: deployment.hook,
      band: deployment.band,
      poolManager: deployment.poolManager,
      aqua: deployment.aqua,
      swapVmRouter: deployment.swapVmRouter,
    },
    runs,
    guard: { file: guardFile, amount: GUARD_AMOUNT },
  };
  write("index.json", index);

  const after = await src.header();
  if (after.sqrtPrice !== header.sqrtPrice) fail("the chain was not left at the deploy state (sqrtPrice differs)");
  console.log("record: done; the chain is at the deploy state");
}

main().catch((e) => fail(e instanceof Error ? e.message : String(e)));
