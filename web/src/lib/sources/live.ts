// Live DataSource: drives the local anvil fork exactly as scripts/src/demo.ts does (D-24, spec "Live source").
// Snapshot discipline (D-23): anvil snapshots are single-use, so every revert is followed at once by a new snapshot,
// BEFORE any swap, and every action ends with the chain back at the deploy state. W is held in memory only.
import { createPublicClient, createWalletClient, http, type Hex, type PublicClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { GUARD_MOVE_AMOUNT } from "../constants.ts";
import { poolSqrtPrice, readSnap, rpc, runSwap, snapsEqual, toRunFile, runToJson, type ChainCtx } from "../engine.ts";
import { guardChecks } from "../guard.ts";
import { decodeSkipReason } from "../decode.ts";
import { usdcPerMumb } from "../format.ts";
import { amountInRaw, bestHint, zeroForOneFor } from "../quoter.ts";
import type { DataSource, DeploymentJson, Direction, GuardFile, Header, QuotePoint, RunFile, Snap } from "../types.ts";


export interface LiveOptions {
  rpcUrl: string;
  deployment: DeploymentJson;
  /** anvil's public key #2; used only after the anvil check below. */
  traderKey: Hex;
  /** The deploy-state snapshot: the `before` of the recorded 1,000 USDC run. Absent = not checked. */
  expectedBefore?: Snap;
  onToast?: (message: string) => void;
  onBusy?: (busy: boolean) => void;
}

export interface LiveSource extends DataSource {
  kind: "live";
  /** "mismatch" until the user chooses to continue; actions refuse while it is "mismatch". */
  deployState(): "ok" | "mismatch" | "unchecked";
  continueAnyway(): void;
  busy(): boolean;
}

export type LiveResult = { source: LiveSource } | { refused: string };

const errText = (e: unknown) => (e instanceof Error ? e.message : String(e));

export async function createLiveSource(o: LiveOptions): Promise<LiveResult> {
  const { deployment: d } = o;

  // ---- connect: refuse anything that is not our anvil fork ----
  if (!/^0x[0-9a-fA-F]{64}$/.test(o.traderKey)) return { refused: "the trader key is missing or not a 32-byte hex key" };
  const transport = http(o.rpcUrl);
  const pub: PublicClient = createPublicClient({ transport, pollingInterval: 100 });
  let version: string;
  try {
    version = await rpc<string>(pub, "web3_clientVersion");
  } catch (e) {
    return { refused: `cannot reach an RPC at ${o.rpcUrl} (${errText(e).split("\n")[0]})` };
  }
  if (!String(version).startsWith("anvil")) {
    return { refused: `${o.rpcUrl} is not anvil (web3_clientVersion is "${version}"): live mode only drives a local anvil fork` };
  }
  const code = await pub.getCode({ address: d.poolManager });
  if (!code || code === "0x") return { refused: `the PoolManager ${d.poolManager} has no code on this chain: is this the fork?` };
  const account = privateKeyToAccount(o.traderKey);
  if (account.address.toLowerCase() !== d.trader.toLowerCase()) {
    return { refused: `the trader key is ${account.address}, but the deployment's trader is ${d.trader}` };
  }
  // Only forkBlockNumber is read from anvil_nodeInfo: forkUrl in the same answer carries our RPC key (gap 8).
  let forkBlock: number;
  try {
    const info = await rpc<{ forkConfig?: { forkBlockNumber?: number | string } }>(pub, "anvil_nodeInfo");
    const n = info.forkConfig?.forkBlockNumber;
    if (n === undefined) return { refused: "this anvil is not a fork of mainnet (no fork block number)" };
    forkBlock = Number(n);
  } catch (e) {
    return { refused: `anvil_nodeInfo failed: ${errText(e).split("\n")[0]}` };
  }

  const c: ChainCtx = {
    d,
    pub,
    wallet: createWalletClient({ account, transport }),
    zeroForOne: zeroForOneFor("usdc-to-mumb", d.usdc, d.mumb),
  };
  const usdcIsCurrency0 = d.usdc.toLowerCase() < d.mumb.toLowerCase();

  // ---- deploy-state check ----
  let state: "ok" | "mismatch" | "unchecked" = o.expectedBefore ? "ok" : "unchecked";
  let acknowledged = false;
  const checkDeployState = async () => {
    if (!o.expectedBefore) return;
    state = snapsEqual(await readSnap(c), o.expectedBefore) ? "ok" : "mismatch";
  };
  await checkDeployState();

  // ---- snapshot discipline ----
  let W: Hex | undefined; // taken lazily at the first action: nothing to hold (or to leak) while the page just sits there
  async function resetW(): Promise<void> {
    if (W !== undefined) {
      const ok = await rpc<boolean>(pub, "evm_revert", [W]);
      if (!ok) {
        // A CLI command consumed our id (reverting to the CLI's older snapshot also drops ours). The chain is wherever the CLI left it.
        o.onToast?.("The CLI reset the chain under us; re-synced.");
        await checkDeployState();
      }
    }
    W = await rpc<Hex>(pub, "evm_snapshot");
  }

  // ---- one action at a time ----
  let isBusy = false;
  async function exclusive<T>(body: () => Promise<T>): Promise<T> {
    if (isBusy) throw new Error("busy: another action is running");
    if (state === "mismatch" && !acknowledged) throw new Error("the chain is not at the deploy state: reset it or choose Continue anyway");
    isBusy = true;
    o.onBusy?.(true);
    try {
      return await body();
    } catch (e) {
      try {
        await resetW(); // leave the chain at the deploy state whatever failed
      } catch (e2) {
        o.onToast?.(`could not restore the snapshot: ${errText(e2)}`);
      }
      throw e;
    } finally {
      isBusy = false;
      o.onBusy?.(false);
    }
  }

  const header = async (): Promise<Header> => {
    const snap = await readSnap(c);
    return {
      pool: {
        fee: d.poolKey.fee,
        tickSpacing: d.poolKey.tickSpacing,
        bandBps: d.bandBps,
        feeE9: d.feeE9,
        usdcIsCurrency0,
      },
      forkBlock,
      sqrtPrice: snap.sqrtPrice.toString(),
      usdcPerMumb: usdcPerMumb(snap.sqrtPrice, usdcIsCurrency0),
      liquidity: snap.liquidity.toString(),
    };
  };

  const compare: DataSource["compare"] = (req, onPoint) =>
    exclusive(async () => {
      if (req.dir !== "usdc-to-mumb") throw new Error("MUMB to USDC is not in this build");
      const { amountIn } = req;
      await resetW();
      const points: QuotePoint[] = [];
      const quote = await bestHint(
        { poolKey: d.poolKey, zeroForOne: c.zeroForOne, amountIn, from: d.trader },
        {
          client: pub,
          swapRouter: d.swapRouter,
          onPoint: (h, out) => {
            const p = { hint: h.toString(), out: out === null ? null : out.toString() };
            points.push(p);
            onPoint?.(p);
          },
        },
      );
      const first = await readSnap(c);
      const poolOnly = await runSwap(c, "pool only", amountIn, 0n);
      await resetW();
      if (!snapsEqual(first, await readSnap(c))) throw new Error("the chain changed under us: the two runs would not start from the same state");
      const split = await runSwap(c, "confluence", amountIn, quote.hint);
      await resetW();

      if (poolOnly.usdcIn !== amountIn || split.usdcIn !== amountIn) throw new Error("the trader did not pay exactly the swap amount");
      if (poolOnly.mumbOut !== quote.poolOnlyOut || split.mumbOut !== quote.splitOut) {
        throw new Error("the real outputs differ from the quoter's simulation");
      }
      return toRunFile({
        block: forkBlock,
        dir: req.dir as Direction,
        amountIn,
        points,
        hint: quote.hint,
        aquaShare: quote.aquaShare,
        poolOnly,
        split,
      }) satisfies RunFile;
    });

  const guard: DataSource["guard"] = (amountIn) =>
    exclusive(async () => {
      const moveIn = amountInRaw(GUARD_MOVE_AMOUNT, "usdc-to-mumb");
      await resetW();
      const quote = await bestHint(
        { poolKey: d.poolKey, zeroForOne: c.zeroForOne, amountIn, from: d.trader },
        { client: pub, swapRouter: d.swapRouter },
      );
      const sqrtBefore = await poolSqrtPrice(c);
      const mover = await runSwap(c, "price move", moveIn, 0n);
      const sqrtAfter = await poolSqrtPrice(c);
      // The same hint as before the move: Aqua's price is now outside the band of the pool's live price.
      const hinted = await runSwap(c, "hinted swap", amountIn, quote.hint);
      const failed = guardChecks(hinted, amountIn).filter(([ok]) => !ok);
      await resetW();
      if (failed.length > 0) throw new Error(`guard checks failed: ${failed.map(([, what]) => what).join("; ")}`);
      const json = runToJson(hinted);
      const file: GuardFile = {
        schema: 1,
        fork: { block: forkBlock },
        amountIn: amountIn.toString(),
        hint: quote.hint.toString(),
        move: { amountIn: moveIn.toString(), out: mover.mumbOut.toString(), sqrtBefore: sqrtBefore.toString(), sqrtAfter: sqrtAfter.toString() },
        hinted: { ...json, skipReason: decodeSkipReason(hinted.skipped!) },
      };
      return file;
    });

  const source: LiveSource = {
    kind: "live",
    header,
    amounts: () => "any",
    compare,
    guard,
    deployState: () => state,
    continueAnyway: () => {
      acknowledged = true;
    },
    busy: () => isBusy,
  };
  return { source };
}
