// Engine: JSON (de)serialisation of runs, and the chain access copied from scripts/src/demo.ts @eb8522b
// (poolIdOf, poolWord, readSnap, sendSwap, runSwap). Browser-safe: viem only. Bigints are decimal strings in JSON.
import {
  concat,
  encodeAbiParameters,
  keccak256,
  toHex,
  type Address,
  type ContractFunctionArgs,
  type Hex,
  type PublicClient,
  type TransactionReceipt,
  type WalletClient,
} from "viem";
import { aquaAbi } from "../../../scripts/src/abis/IAqua.ts";
import { mockMumbAbi } from "../../../scripts/src/abis/MockMUMB.ts";
import { poolSwapTestAbi } from "../../../scripts/src/abis/PoolSwapTest.ts";
import { MAX_PRICE_LIMIT, MIN_PRICE_LIMIT, SWAP_GAS_LIMIT } from "./constants.ts";
import { decodeSkipReason, legsFromLogs } from "./decode.ts";
import type {
  DeploymentJson,
  Direction,
  QuotePoint,
  RunFile,
  RunJson,
  RunRecord,
  Snap,
  SnapJson,
} from "./types.ts";

// ---- JSON <-> records ----------------------------------------------------------

const SNAP_KEYS = [
  "traderMumb",
  "traderUsdc",
  "priyaMumb",
  "priyaUsdc",
  "aquaMumb",
  "aquaUsdc",
  "poolManagerMumb",
  "sqrtPrice",
  "liquidity",
] as const satisfies readonly (keyof Snap)[];

export function snapToJson(s: Snap): SnapJson {
  const out = {} as SnapJson;
  for (const k of SNAP_KEYS) out[k] = s[k].toString();
  return out;
}

export function snapFromJson(j: SnapJson): Snap {
  const out = {} as Snap;
  for (const k of SNAP_KEYS) out[k] = BigInt(j[k]);
  return out;
}

export const snapsEqual = (a: Snap, b: Snap) => SNAP_KEYS.every((k) => a[k] === b[k]);

export function runToJson(r: RunRecord): RunJson {
  // Keys are added in a fixed order and optional ones only when present, so two records serialise identically.
  const out: RunJson = {
    hint: r.hint.toString(),
    before: snapToJson(r.before),
    after: snapToJson(r.after),
    usdcIn: r.usdcIn.toString(),
    mumbOut: r.mumbOut.toString(),
    gasUsed: "",
  };
  const ordered: Record<string, unknown> = { ...out };
  delete ordered.gasUsed;
  if (r.fill) ordered.fill = { amountIn: r.fill.amountIn.toString(), amountOut: r.fill.amountOut.toString() };
  if (r.skipped !== undefined) {
    ordered.skipped = r.skipped;
    ordered.skipReason = decodeSkipReason(r.skipped);
  }
  ordered.gasUsed = r.gasUsed.toString();
  return ordered as unknown as RunJson;
}

export function runFromJson(j: RunJson, label: string): RunRecord {
  const rec: RunRecord = {
    label,
    hint: BigInt(j.hint),
    before: snapFromJson(j.before),
    after: snapFromJson(j.after),
    usdcIn: BigInt(j.usdcIn),
    mumbOut: BigInt(j.mumbOut),
    gasUsed: BigInt(j.gasUsed),
  };
  if (j.fill) rec.fill = { amountIn: BigInt(j.fill.amountIn), amountOut: BigInt(j.fill.amountOut) };
  if (j.skipped !== undefined) rec.skipped = j.skipped;
  return rec;
}

/** Builds the RunFile. The quote points are sorted by hint: they arrive in completion order (gap 7). */
export function toRunFile(a: {
  block: number;
  dir: Direction;
  amountIn: bigint;
  points: QuotePoint[];
  hint: bigint;
  aquaShare: number;
  poolOnly: RunRecord;
  split: RunRecord;
}): RunFile {
  const points = [...a.points].sort((x, y) => (BigInt(x.hint) < BigInt(y.hint) ? -1 : BigInt(x.hint) > BigInt(y.hint) ? 1 : 0));
  return {
    schema: 1,
    fork: { block: a.block },
    request: { dir: a.dir, amountIn: a.amountIn.toString() },
    quote: { points, hint: a.hint.toString(), aquaShare: a.aquaShare },
    poolOnly: runToJson(a.poolOnly),
    split: runToJson(a.split),
  };
}

/** Two-space JSON with a trailing newline: the committed form of every recorded file. */
export const stringifyRunFile = (f: unknown): string => `${JSON.stringify(f, null, 2)}\n`;

// ---- chain access ---------------------------------------------------------------

export interface ChainCtx {
  d: DeploymentJson;
  pub: PublicClient;
  wallet: WalletClient;
  zeroForOne: boolean;
}

export const rpc = <T>(pub: PublicClient, method: string, params?: unknown[]) =>
  pub.request({ method, params } as never) as Promise<T>;

const poolKeyTuple = [
  {
    type: "tuple",
    components: [
      { name: "currency0", type: "address" },
      { name: "currency1", type: "address" },
      { name: "fee", type: "uint24" },
      { name: "tickSpacing", type: "int24" },
      { name: "hooks", type: "address" },
    ],
  },
] as const;

export const poolIdOf = (d: DeploymentJson): Hex => keccak256(encodeAbiParameters(poolKeyTuple, [d.poolKey]));

/** A word of the pool's `Pool.State` in the PoolManager: `pools` is storage slot 6 (StateLibrary.POOLS_SLOT). */
async function poolWord(c: ChainCtx, offset: bigint): Promise<bigint> {
  const stateSlot = BigInt(keccak256(concat([poolIdOf(c.d), toHex(6n, { size: 32 })])));
  const word = await c.pub.getStorageAt({ address: c.d.poolManager, slot: toHex(stateSlot + offset, { size: 32 }) });
  return BigInt(word ?? "0x0");
}

export const poolSqrtPrice = async (c: ChainCtx) => (await poolWord(c, 0n)) & ((1n << 160n) - 1n);
const poolLiquidity = async (c: ChainCtx) => (await poolWord(c, 3n)) & ((1n << 128n) - 1n);

export async function readSnap(c: ChainCtx): Promise<Snap> {
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

/** The trader's exact-input swap at the explicit gas limit (D-20). Throws if it reverts. */
export async function sendSwap(c: ChainCtx, amountIn: bigint, hint: bigint): Promise<TransactionReceipt> {
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

/** USDC in, MUMB out only: the trader's MUMB balance is the output (sendSwap/zeroForOne follow c). */
export async function runSwap(c: ChainCtx, label: string, amountIn: bigint, hint: bigint): Promise<RunRecord> {
  const before = await readSnap(c);
  const receipt = await sendSwap(c, amountIn, hint);
  const after = await readSnap(c);
  const legs = legsFromLogs(receipt.logs, c.d.hook);
  const rec: RunRecord = {
    label,
    hint,
    before,
    after,
    usdcIn: before.traderUsdc - after.traderUsdc,
    mumbOut: after.traderMumb - before.traderMumb,
    gasUsed: receipt.gasUsed,
  };
  if (legs.fill) rec.fill = legs.fill;
  if (legs.skipped) rec.skipped = legs.skipped.reason;
  return rec;
}
