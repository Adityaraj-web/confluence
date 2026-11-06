// Replay source: serves web/public/runs/*.json, recorded by the same engine against the fork. No chain access.
// It emits the same phases as the live source, in the same order, with short pacing so the UI looks the same.
import { usdcPerMumb } from "../format.ts";
import { amountInRaw } from "../quoter.ts";
import { loadIndex, loadJson } from "../runs.ts";
import type { DataSource, Direction, GuardFile, Header, Phase, QuotePoint, RunFile, RunsIndex } from "../types.ts";

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export async function createReplaySource(): Promise<{ source: DataSource } | { refused: string }> {
  const index: RunsIndex | null = await loadIndex();
  if (!index) return { refused: "no recorded runs found (web/public/runs/index.json)" };

  const fileFor = (dir: Direction, amountIn: bigint): string | undefined =>
    index.runs.find((r) => r.dir === dir && amountInRaw(r.amount, r.dir) === amountIn)?.file;

  const phase = async (cb: ((p: Phase) => void) | undefined, p: Phase, ms: number) => {
    cb?.(p);
    await sleep(ms);
  };

  const source: DataSource = {
    kind: "replay",
    async header(): Promise<Header> {
      const first = index.runs.find((r) => r.amount === "1000") ?? index.runs[0];
      if (!first) throw new Error("index.json lists no runs");
      const f = await loadJson<RunFile>(first.file);
      const snap = f.poolOnly.before;
      return {
        pool: index.pool,
        forkBlock: index.fork.block,
        sqrtPrice: snap.sqrtPrice,
        usdcPerMumb: usdcPerMumb(BigInt(snap.sqrtPrice), index.pool.usdcIsCurrency0),
        liquidity: snap.liquidity,
      };
    },
    amounts(dir) {
      return index.runs.filter((r) => r.dir === dir).map((r) => r.amount);
    },
    async compare(req, onPoint, onPhase) {
      const file = fileFor(req.dir, req.amountIn);
      if (!file) throw new Error("replay has only the recorded amounts");
      const f = await loadJson<RunFile>(file);
      await phase(onPhase, "quoting", 150);
      const pts: QuotePoint[] = f.quote.points;
      for (const p of pts) {
        onPoint?.(p);
        await sleep(Math.max(10, Math.floor(700 / Math.max(1, pts.length))));
      }
      await phase(onPhase, "pool-only", 450);
      await phase(onPhase, "confluence", 450);
      return f;
    },
    async guard(amountIn): Promise<GuardFile> {
      if (amountInRaw(index.guard.amount, "usdc-to-mumb") !== amountIn) throw new Error("replay has only the recorded guard amount");
      await sleep(900);
      return loadJson<GuardFile>(index.guard.file);
    },
  };
  return { source };
}
