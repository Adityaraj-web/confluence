// F09 demo runner (docs/DEMO.md steps 3-6). Subcommands:
//   snapshot  take the chain snapshot after `deploy` and save its id in deployments/local.json
//   reset     revert to the saved snapshot and snapshot again; no swaps
//   run       pool-only swap, then the split swap with the quoter's hint, from identical state; prints the table
//   guard     move the pool price, then show the Aqua leg skipped (AquaSkipped) while the swap still succeeds
//
// Snapshot discipline (probed by test_F09_live_snapshotRevertIsReusableAfterResnapshot): anvil consumes a snapshot id
// on revert, so every revert is followed at once by a new snapshot, BEFORE any swap. Every command leaves the chain at
// the deploy state with a live snapshot id saved, whether it succeeds or fails.
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import {
  concat,
  createPublicClient,
  createWalletClient,
  decodeErrorResult,
  encodeAbiParameters,
  formatUnits,
  http,
  keccak256,
  parseEventLogs,
  toHex,
  type Address,
  type ContractFunctionArgs,
  type Hex,
  type PublicClient,
  type TransactionReceipt,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { aquaAbi } from "./abis/IAqua.js";
import { confluenceHookAbi } from "./abis/ConfluenceHook.js";
import { mockMumbAbi } from "./abis/MockMUMB.js";
import { poolPriceBandExtructionAbi } from "./abis/PoolPriceBandExtruction.js";
import { poolSwapTestAbi } from "./abis/PoolSwapTest.js";
import {
  DEPLOYMENT_PATH,
  MUMB_DECIMALS,
  SWAP_GAS_LIMIT,
  USDC_DECIMALS,
  loadDeployment,
  rpcUrl,
  type Deployment,
} from "./config.js";
import { amountInRaw, bestHint, zeroForOneFor } from "./quoter.js";
import { poolKeyTuple } from "./shipStrategy.js";

export const LAST_DEMO_PATH = resolve(dirname(DEPLOYMENT_PATH), "last-demo.json");

/** The swap the demo makes, and the trade that moves the pool for the guard (measured: PROGRESS / D-23). */
const DEMO_AMOUNT = "1000";
const GUARD_MOVE_AMOUNT = "1500";

// TickMath.MIN_SQRT_PRICE + 1 and MAX_SQRT_PRICE - 1: no price limit in practice (same values as quoter.ts).
const MIN_PRICE_LIMIT = 4295128740n;
const MAX_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341n;

// ---- pure helpers (unit-tested without a chain) --------------------------------

export interface Snap {
  traderMumb: bigint;
  traderUsdc: bigint;
  priyaMumb: bigint;
  priyaUsdc: bigint;
  /** Priya's Aqua virtual balances for the shipped strategy. */
  aquaMumb: bigint;
  aquaUsdc: bigint;
  /** Only this pool holds MUMB, so this is the pool's locked MUMB. */
  poolManagerMumb: bigint;
  /** slot0 sqrtPriceX96 of the pool. */
  sqrtPrice: bigint;
  /** The pool's in-range liquidity L. A swap inside the range never changes it, so it is kept in last-demo.json only. */
  liquidity: bigint;
}

export interface RunRecord {
  label: string;
  /** USDC handed to Aqua (the hookData hint), base units. */
  hint: bigint;
  before: Snap;
  after: Snap;
  usdcIn: bigint;
  mumbOut: bigint;
  fill?: { amountIn: bigint; amountOut: bigint };
  /** The AquaSkipped reason bytes, when the hook skipped Aqua. */
  skipped?: Hex;
  gasUsed: bigint;
}

const U = (v: bigint) => formatUnits(v, USDC_DECIMALS);
const M = (v: bigint) => formatUnits(v, MUMB_DECIMALS);

/** `diff / base` as a percentage with two decimals, rounded down: "3.10%". */
function percent(diff: bigint, base: bigint): string {
  const hundredths = (diff * 10_000n) / base;
  return `${hundredths / 100n}.${(hundredths % 100n).toString().padStart(2, "0")}%`;
}

/** The pool's slot0 price (sqrtPrice squared) moved by this much, as a percentage of the price before: "2.37%". */
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

const REASON_ABI = [...confluenceHookAbi, ...poolPriceBandExtructionAbi].filter((e) => e.type === "error");

/** Turns the bytes of an `AquaSkipped` event into words. The reason is an ABI-encoded custom error (D-20). */
export function decodeSkipReason(reason: Hex): string {
  if (reason === "0x") return "empty reason (the router ran out of gas)";
  const unknown = () =>
    reason.length >= 10 ? `unknown error ${reason.slice(0, 10)} (raw ${reason})` : `unknown reason (raw ${reason})`;
  try {
    const { errorName, args } = decodeErrorResult({ abi: REASON_ABI, data: reason });
    const item = REASON_ABI.find((e) => e.name === errorName);
    if (!item) return unknown();
    const values = (args ?? []) as readonly unknown[];
    const text = `${errorName}(${values.map((v, i) => `${item.inputs[i]?.name}=${v}`).join(", ")})`;
    if (errorName === "PoolPriceBandExceeded") {
      const [exec, pool, band] = values as [bigint, bigint, number];
      const diff = exec > pool ? exec - pool : pool - exec;
      return `${text}: fill price ${percent(diff, pool)} off the pool price, band ${percent(BigInt(band), 10_000n)}`;
    }
    return text;
  } catch {
    return unknown();
  }
}

/** The hook's own events in a receipt's logs. Other contracts' logs are ignored. */
export function legsFromLogs(
  logs: readonly Parameters<typeof parseEventLogs>[0]["logs"][number][],
  hook: Address,
): { fill?: { amountIn: bigint; amountOut: bigint }; skipped?: { reason: Hex } } {
  const mine = logs.filter((l) => l.address.toLowerCase() === hook.toLowerCase());
  const events = parseEventLogs({ abi: confluenceHookAbi, logs: mine, strict: false });
  const fills = events.filter((e) => e.eventName === "AquaFill");
  const skips = events.filter((e) => e.eventName === "AquaSkipped");
  if (fills.length > 1) throw new Error(`more than one AquaFill in one swap (${fills.length})`);
  if (skips.length > 1) throw new Error(`more than one AquaSkipped in one swap (${skips.length})`);
  const out: { fill?: { amountIn: bigint; amountOut: bigint }; skipped?: { reason: Hex } } = {};
  const fill = fills[0];
  if (fill && fill.eventName === "AquaFill") {
    const { amountIn, amountOut } = fill.args;
    if (amountIn === undefined || amountOut === undefined) throw new Error("malformed AquaFill event");
    out.fill = { amountIn, amountOut };
  }
  const skip = skips[0];
  if (skip && skip.eventName === "AquaSkipped") {
    if (skip.args.reason === undefined) throw new Error("malformed AquaSkipped event");
    out.skipped = { reason: skip.args.reason };
  }
  return out;
}

const legsOf = (r: RunRecord) => {
  const aIn = r.fill?.amountIn ?? 0n;
  const aOut = r.fill?.amountOut ?? 0n;
  return { aIn, aOut, pIn: r.usdcIn - aIn, pOut: r.mumbOut - aOut };
};

const eventCell = (r: RunRecord) => (r.fill ? "AquaFill" : r.skipped !== undefined ? "AquaSkipped" : "none");

/** Pool-only and split side by side. A pure function of the two records. */
export function formatTable(p: RunRecord, s: RunRecord): string {
  const lp = legsOf(p);
  const ls = legsOf(s);
  const rows: [string, string, string][] = [
    ["USDC in", U(p.usdcIn), U(s.usdcIn)],
    ["hint (USDC to Aqua)", U(p.hint), U(s.hint)],
    ["MUMB out", M(p.mumbOut), M(s.mumbOut)],
    [
      "avg price (USDC per MUMB)",
      avgPrice(p.usdcIn, p.mumbOut, USDC_DECIMALS, MUMB_DECIMALS),
      avgPrice(s.usdcIn, s.mumbOut, USDC_DECIMALS, MUMB_DECIMALS),
    ],
    ["Aqua leg: USDC in", U(lp.aIn), U(ls.aIn)],
    ["Aqua leg: MUMB out", M(lp.aOut), M(ls.aOut)],
    ["pool leg: USDC in", U(lp.pIn), U(ls.pIn)],
    ["pool leg: MUMB out", M(lp.pOut), M(ls.pOut)],
    ["Priya wallet MUMB, before", M(p.before.priyaMumb), M(s.before.priyaMumb)],
    ["Priya wallet MUMB, after", M(p.after.priyaMumb), M(s.after.priyaMumb)],
    ["Priya wallet USDC, before", U(p.before.priyaUsdc), U(s.before.priyaUsdc)],
    ["Priya wallet USDC, after", U(p.after.priyaUsdc), U(s.after.priyaUsdc)],
    ["Priya Aqua MUMB, before", M(p.before.aquaMumb), M(s.before.aquaMumb)],
    ["Priya Aqua MUMB, after", M(p.after.aquaMumb), M(s.after.aquaMumb)],
    ["Priya Aqua USDC, before", U(p.before.aquaUsdc), U(s.before.aquaUsdc)],
    ["Priya Aqua USDC, after", U(p.after.aquaUsdc), U(s.after.aquaUsdc)],
    [
      "pool price move (slot0)",
      priceMovePercent(p.before.sqrtPrice, p.after.sqrtPrice),
      priceMovePercent(s.before.sqrtPrice, s.after.sqrtPrice),
    ],
    ["PoolManager MUMB, before", M(p.before.poolManagerMumb), M(s.before.poolManagerMumb)],
    ["PoolManager MUMB, after", M(p.after.poolManagerMumb), M(s.after.poolManagerMumb)],
    ["hook event", eventCell(p), eventCell(s)],
    ["gas used", p.gasUsed.toString(), s.gasUsed.toString()],
  ];
  const w = [28, 26, 26] as const;
  const line = (a: string, b: string, c: string) => `${a.padEnd(w[0])}${b.padStart(w[1])}${c.padStart(w[2])}`;
  const out = [line("", "POOL ONLY", "CONFLUENCE"), "-".repeat(w[0] + w[1] + w[2])];
  for (const [a, b, c] of rows) out.push(line(a, b, c));
  out.push("-".repeat(w[0] + w[1] + w[2]));

  const gain = s.mumbOut - p.mumbOut;
  const abs = gain < 0n ? -gain : gain;
  const hundredthsBps = (abs * 1_000_000n) / p.mumbOut;
  const sign = gain < 0n ? "-" : "+";
  out.push(
    `gain vs pool only: ${sign}${M(abs)} MUMB (${sign}${hundredthsBps / 100n}.${(hundredthsBps % 100n).toString().padStart(2, "0")} bps)`,
  );
  return out.join("\n");
}

/** What `guard` must show for the hinted swap after the pool price moved. Pure: [passed, what] pairs. */
export function guardChecks(hinted: RunRecord, amountIn: bigint): [boolean, string][] {
  const priyaUntouched =
    hinted.before.priyaMumb === hinted.after.priyaMumb &&
    hinted.before.priyaUsdc === hinted.after.priyaUsdc &&
    hinted.before.aquaMumb === hinted.after.aquaMumb &&
    hinted.before.aquaUsdc === hinted.after.aquaUsdc;
  return [
    [hinted.skipped !== undefined, "AquaSkipped was emitted"],
    [hinted.fill === undefined, "no AquaFill: Priya was not filled"],
    [
      hinted.skipped !== undefined && decodeSkipReason(hinted.skipped).startsWith("PoolPriceBandExceeded("),
      "the skip reason is PoolPriceBandExceeded (the guard, not some other skip)",
    ],
    [hinted.usdcIn === amountIn && hinted.mumbOut > 0n, "the trader paid the swap amount and received MUMB"],
    [priyaUntouched, "Priya's wallet and Aqua balances are untouched"],
  ];
}

// ---- chain access --------------------------------------------------------------

interface Ctx {
  d: Deployment;
  pub: PublicClient;
  wallet: WalletClient;
  zeroForOne: boolean;
}

function makeCtx(): Ctx {
  const d = loadDeployment();
  const pk = process.env.TRADER_PRIVATE_KEY;
  if (!pk || !/^0x[0-9a-fA-F]{64}$/.test(pk)) {
    throw new Error("TRADER_PRIVATE_KEY is missing or not a 32-byte hex key (it is in .env.example)");
  }
  const account = privateKeyToAccount(pk as Hex);
  if (account.address.toLowerCase() !== d.trader.toLowerCase()) {
    throw new Error(`TRADER_PRIVATE_KEY is ${account.address}, but the deployment's trader is ${d.trader}`);
  }
  const transport = http(rpcUrl());
  return {
    d,
    pub: createPublicClient({ transport, pollingInterval: 100 }),
    wallet: createWalletClient({ account, transport }),
    zeroForOne: zeroForOneFor("usdc-to-mumb", d.usdc, d.mumb),
  };
}

const rpc = <T>(pub: PublicClient, method: string, params?: unknown[]) =>
  pub.request({ method, params } as never) as Promise<T>;

function saveSnapshotId(id: Hex): void {
  const raw = JSON.parse(readFileSync(DEPLOYMENT_PATH, "utf8")) as Record<string, unknown>;
  raw.snapshotId = id;
  writeFileSync(DEPLOYMENT_PATH, `${JSON.stringify(raw, null, 2)}\n`);
}

/** Holds the one live snapshot id. `resetTo` reverts to it and snapshots again straight away. */
class Session {
  constructor(
    private readonly pub: PublicClient,
    public id: Hex,
  ) {}

  static fromDeployment(c: Ctx): Session {
    if (!c.d.snapshotId) {
      throw new Error("deployments/local.json has no snapshotId: run `deploy` on a fresh fork first");
    }
    return new Session(c.pub, c.d.snapshotId as Hex);
  }

  async resetTo(): Promise<Hex> {
    const ok = await rpc<boolean>(this.pub, "evm_revert", [this.id]);
    if (!ok) {
      throw new Error(
        `snapshot ${this.id} is not valid (anvil snapshots are single-use, or the fork was restarted): ` +
          "stop the fork, run `fork` again, then `deploy`",
      );
    }
    this.id = await rpc<Hex>(this.pub, "evm_snapshot");
    return this.id;
  }
}

/** If the body fails, put the chain back at the deploy state with a live saved snapshot, then rethrow. */
async function withRecovery<T>(sess: Session, body: () => Promise<T>): Promise<T> {
  try {
    return await body();
  } catch (e) {
    try {
      await sess.resetTo();
      saveSnapshotId(sess.id);
      console.error("the chain was put back at the deploy snapshot after the error");
    } catch (e2) {
      console.error(`could not restore the snapshot: ${e2 instanceof Error ? e2.message : e2}`);
    }
    throw e;
  }
}

const poolIdOf = (d: Deployment): Hex => keccak256(encodeAbiParameters(poolKeyTuple, [d.poolKey]));

/** A word of the pool's `Pool.State` in the PoolManager: `pools` is storage slot 6 (StateLibrary.POOLS_SLOT). */
async function poolWord(c: Ctx, offset: bigint): Promise<bigint> {
  const stateSlot = BigInt(keccak256(concat([poolIdOf(c.d), toHex(6n, { size: 32 })])));
  const word = await c.pub.getStorageAt({
    address: c.d.poolManager,
    slot: toHex(stateSlot + offset, { size: 32 }),
  });
  return BigInt(word ?? "0x0");
}

const poolSqrtPrice = async (c: Ctx) => (await poolWord(c, 0n)) & ((1n << 160n) - 1n); // slot0, low 160 bits
const poolLiquidity = async (c: Ctx) => (await poolWord(c, 3n)) & ((1n << 128n) - 1n); // StateLibrary.LIQUIDITY_OFFSET

async function readSnap(c: Ctx): Promise<Snap> {
  const { d, pub } = c;
  const bal = (token: Address, who: Address) =>
    pub.readContract({ address: token, abi: mockMumbAbi, functionName: "balanceOf", args: [who] });
  const virtual = async (token: Address) =>
    (
      await pub.readContract({
        address: d.aqua,
        abi: aquaAbi,
        functionName: "rawBalances",
        args: [d.maker, d.swapVmRouter, d.expectedStrategyHash, token],
      })
    )[0];
  const [traderMumb, traderUsdc, priyaMumb, priyaUsdc, aquaMumb, aquaUsdc, poolManagerMumb, sqrtPrice, liquidity] =
    await Promise.all([
      bal(d.mumb, d.trader),
      bal(d.usdc, d.trader),
      bal(d.mumb, d.maker),
      bal(d.usdc, d.maker),
      virtual(d.mumb),
      virtual(d.usdc),
      bal(d.mumb, d.poolManager),
      poolSqrtPrice(c),
      poolLiquidity(c),
    ]);
  return {
    traderMumb,
    traderUsdc,
    priyaMumb,
    priyaUsdc,
    aquaMumb: BigInt(aquaMumb),
    aquaUsdc: BigInt(aquaUsdc),
    poolManagerMumb,
    sqrtPrice,
    liquidity,
  };
}

/** The trader's exact-input swap, USDC for MUMB, at the explicit gas limit (D-20). Throws if it reverts. */
async function sendSwap(c: Ctx, amountIn: bigint, hint: bigint): Promise<TransactionReceipt> {
  const args: ContractFunctionArgs<typeof poolSwapTestAbi, "payable", "swap"> = [
    c.d.poolKey,
    {
      zeroForOne: c.zeroForOne,
      amountSpecified: -amountIn,
      sqrtPriceLimitX96: c.zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT,
    },
    { takeClaims: false, settleUsingBurn: false },
    encodeAbiParameters([{ type: "uint256" }], [hint]),
  ];
  const hash = await c.wallet.writeContract({
    address: c.d.swapRouter,
    abi: poolSwapTestAbi,
    functionName: "swap",
    args,
    gas: SWAP_GAS_LIMIT,
    chain: null,
    account: c.wallet.account!,
  });
  const receipt = await c.pub.waitForTransactionReceipt({ hash, pollingInterval: 100 });
  if (receipt.status !== "success") throw new Error(`the swap reverted (hint ${hint}, tx ${hash})`);
  return receipt;
}

async function runSwap(c: Ctx, label: string, amountIn: bigint, hint: bigint): Promise<RunRecord> {
  const before = await readSnap(c);
  const receipt = await sendSwap(c, amountIn, hint);
  const after = await readSnap(c);
  const legs = legsFromLogs(receipt.logs, c.d.hook);
  return {
    label,
    hint,
    before,
    after,
    usdcIn: before.traderUsdc - after.traderUsdc,
    mumbOut: after.traderMumb - before.traderMumb,
    fill: legs.fill,
    skipped: legs.skipped?.reason,
    gasUsed: receipt.gasUsed,
  };
}

// ---- checks ---------------------------------------------------------------------

class Checks {
  failed = 0;
  check(ok: boolean, what: string): void {
    console.log(`${ok ? "ok  " : "FAIL"} ${what}`);
    if (!ok) this.failed++;
  }
  done(): void {
    if (this.failed > 0) throw new Error(`${this.failed} check(s) failed`);
  }
}

const jsonReplacer = (_: string, v: unknown) => (typeof v === "bigint" ? v.toString() : v);

// ---- commands -------------------------------------------------------------------

async function cmdSnapshot(): Promise<void> {
  const c = makeCtx();
  const id = await rpc<Hex>(c.pub, "evm_snapshot");
  saveSnapshotId(id);
  const block = await c.pub.getBlockNumber({ cacheTime: 0 });
  console.log(`snapshot ${id} taken at block ${block} and saved to deployments/local.json`);
}

async function cmdReset(): Promise<void> {
  const c = makeCtx();
  const sess = Session.fromDeployment(c);
  const old = sess.id;
  const id = await sess.resetTo();
  saveSnapshotId(id);
  const block = await c.pub.getBlockNumber({ cacheTime: 0 });
  const snap = await readSnap(c);
  console.log(`reverted to snapshot ${old} (block ${block}); new snapshot ${id} saved to deployments/local.json`);
  console.log(`trader: ${U(snap.traderUsdc)} USDC, ${M(snap.traderMumb)} MUMB`);
  console.log(`Priya wallet: ${U(snap.priyaUsdc)} USDC, ${M(snap.priyaMumb)} MUMB; Aqua: ${U(snap.aquaUsdc)} USDC, ${M(snap.aquaMumb)} MUMB`);
  console.log(`pool liquidity ${snap.liquidity}, PoolManager MUMB ${M(snap.poolManagerMumb)}`);
}

async function cmdRun(amount: string): Promise<void> {
  const c = makeCtx();
  const sess = Session.fromDeployment(c);
  const amountIn = amountInRaw(amount, "usdc-to-mumb");

  await withRecovery(sess, async () => {
    // revert(S) -> S1 = snapshot -> pool-only swap
    await sess.resetTo();
    const poolOnly = await runSwap(c, "pool only", amountIn, 0n);
    // revert(S1) -> S2 = snapshot -> quote -> split swap
    await sess.resetTo();
    const quote = await bestHint(
      { poolKey: c.d.poolKey, zeroForOne: c.zeroForOne, amountIn, from: c.d.trader },
      { client: c.pub, swapRouter: c.d.swapRouter },
    );
    const split = await runSwap(c, "confluence", amountIn, quote.hint);
    // revert(S2) -> S3 = snapshot, saved
    await sess.resetTo();
    saveSnapshotId(sess.id);

    console.log(`${amount} USDC -> MUMB through the v4 pool, as the trader, gas limit ${SWAP_GAS_LIMIT}`);
    console.log(`quoter: hint ${quote.hint} (${(quote.aquaShare * 100).toFixed(2)}% of the swap to Aqua)\n`);
    console.log(formatTable(poolOnly, split));
    console.log("");

    const k = new Checks();
    const fill = split.fill;
    k.check(JSON.stringify(poolOnly.before, jsonReplacer) === JSON.stringify(split.before, jsonReplacer), "both runs started from identical state");
    k.check(poolOnly.usdcIn === amountIn && split.usdcIn === amountIn, "the trader paid exactly the swap amount in both runs");
    k.check(poolOnly.fill === undefined && poolOnly.skipped === undefined, "pool-only: no Aqua event (hint 0 is silent)");
    k.check(fill !== undefined && split.skipped === undefined, "split: AquaFill emitted, no AquaSkipped");
    k.check(split.mumbOut > poolOnly.mumbOut, "split MUMB out > pool-only MUMB out");
    k.check(poolOnly.mumbOut === quote.poolOnlyOut && split.mumbOut === quote.splitOut, "real outputs equal the quoter's simulation");
    if (fill) {
      k.check(split.before.priyaMumb - split.after.priyaMumb === fill.amountOut, "Priya's wallet MUMB fell by exactly the Aqua leg's MUMB out");
      k.check(split.before.aquaMumb - split.after.aquaMumb === fill.amountOut, "Priya's Aqua MUMB fell by the same amount");
      k.check(split.after.aquaUsdc - split.before.aquaUsdc === fill.amountIn, "Priya's Aqua USDC rose by exactly the Aqua leg's USDC in");
    }
    k.check(
      poolOnly.before.liquidity === poolOnly.after.liquidity && split.before.liquidity === split.after.liquidity,
      "the pool's liquidity is unchanged by both swaps",
    );
    k.done();

    const gain = split.mumbOut - poolOnly.mumbOut;
    writeFileSync(
      LAST_DEMO_PATH,
      `${JSON.stringify({ amountInUsdc: amountIn, quote, poolOnly, confluence: split, gainMumb: gain }, jsonReplacer, 2)}\n`,
    );
    console.log(`wrote ${LAST_DEMO_PATH}`);
  });
}

async function cmdGuard(amount: string): Promise<void> {
  const c = makeCtx();
  const sess = Session.fromDeployment(c);
  const amountIn = amountInRaw(amount, "usdc-to-mumb");
  const moveIn = amountInRaw(GUARD_MOVE_AMOUNT, "usdc-to-mumb");

  await withRecovery(sess, async () => {
    await sess.resetTo(); // S1
    const quote = await bestHint(
      { poolKey: c.d.poolKey, zeroForOne: c.zeroForOne, amountIn, from: c.d.trader },
      { client: c.pub, swapRouter: c.d.swapRouter },
    );
    console.log(`before the move the quoter picks hint ${quote.hint} (${(quote.aquaShare * 100).toFixed(2)}% to Aqua): ` +
      `split ${M(quote.splitOut)} MUMB vs pool-only ${M(quote.poolOnlyOut)}`);

    const p0 = await poolSqrtPrice(c);
    const mover = await runSwap(c, "price move", moveIn, 0n);
    const p1 = await poolSqrtPrice(c);
    console.log(`moved the pool with a ${GUARD_MOVE_AMOUNT} USDC pool-only trade (${M(mover.mumbOut)} MUMB out): ` +
      `pool price moved ${priceMovePercent(p0, p1)}`);

    // The same hint as before the move: Aqua's price is now outside the band of the pool's live price.
    const hinted = await runSwap(c, "hinted swap", amountIn, quote.hint);
    console.log("");
    console.log(`the hinted swap SUCCEEDED (${amount} USDC, hint ${quote.hint}, gas used ${hinted.gasUsed})`);
    console.log(`trader MUMB out (pool-only fill): ${M(hinted.mumbOut)} MUMB for ${U(hinted.usdcIn)} USDC`);
    console.log(`AquaSkipped: ${hinted.skipped === undefined ? "(not emitted)" : decodeSkipReason(hinted.skipped)}`);
    console.log("");

    const k = new Checks();
    for (const [ok, what] of guardChecks(hinted, amountIn)) k.check(ok, what);
    await sess.resetTo(); // S2, back at the deploy state
    saveSnapshotId(sess.id);
    k.done();
  });
}

// ---- entry ----------------------------------------------------------------------

function amountArg(argv: string[]): string {
  const i = argv.indexOf("--amount");
  const v = i >= 0 ? argv[i + 1] : DEMO_AMOUNT;
  if (v === undefined || !/^\d+(\.\d+)?$/.test(v)) throw new Error("--amount must be a positive decimal such as 1000");
  return v;
}

async function main(): Promise<void> {
  const [cmd, ...rest] = process.argv.slice(2);
  switch (cmd) {
    case "snapshot":
      return cmdSnapshot();
    case "reset":
      return cmdReset();
    case "run":
      return cmdRun(amountArg(rest));
    case "guard":
      return cmdGuard(amountArg(rest));
    default:
      throw new Error("usage: demo.ts snapshot | reset | run [--amount 1000] | guard [--amount 1000]");
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e) => {
    console.error(e instanceof Error ? e.message : e);
    process.exit(1);
  });
}
