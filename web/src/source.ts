// Chooses the data source. Dev server + a reachable anvil fork = live. Anything else = replay (added in step 6).
// A refusal is returned with its reason so the UI can show it; it never throws.
import { loadJson } from "./lib/runs.ts";
import { snapFromJson } from "./lib/engine.ts";
import { createLiveSource, type LiveSource } from "./lib/sources/live.ts";
import type { DataSource, DeploymentJson, RunFile, Snap } from "./lib/types.ts";

export interface Connection {
  source: DataSource | null;
  live: LiveSource | null;
  /** Why live mode is not in use, when it is not. */
  refused: string | null;
}

export async function connect(cb: { onToast: (m: string) => void; onBusy: (b: boolean) => void }): Promise<Connection> {
  let refused: string | null = null;
  if (import.meta.env.DEV) {
    try {
      const res = await fetch("/__local/deployment.json", { cache: "no-store" });
      if (!res.ok) throw new Error("deployments/local.json not found: run `pnpm --dir scripts run deploy`");
      const deployment = (await res.json()) as DeploymentJson;
      let expectedBefore: Snap | undefined;
      try {
        expectedBefore = snapFromJson((await loadJson<RunFile>("usdc-to-mumb-1000.json")).poolOnly.before);
      } catch {
        expectedBefore = undefined; // nothing recorded yet: the deploy-state check is skipped
      }
      const rpcUrl = new URLSearchParams(location.search).get("rpc") ?? "http://127.0.0.1:8545";
      const r = await createLiveSource({
        rpcUrl,
        deployment,
        traderKey: __TRADER_KEY__ as `0x${string}`,
        expectedBefore,
        onToast: cb.onToast,
        onBusy: cb.onBusy,
      });
      if ("source" in r) return { source: r.source, live: r.source, refused: null };
      refused = r.refused;
    } catch (e) {
      refused = e instanceof Error ? e.message : String(e);
    }
  } else {
    refused = "this build has no chain to drive";
  }
  // Step 6 replaces this with the replay source.
  return { source: null, live: null, refused };
}
