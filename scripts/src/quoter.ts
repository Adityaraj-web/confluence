// F07 off-chain quoter: picks the Aqua hint that gives the trader the most output.
// ARCHITECTURE section 7. Simulation only (eth_call); nothing is sent.
import { pathToFileURL } from "node:url";
import {
  HttpRequestError,
  TimeoutError,
  createPublicClient,
  encodeAbiParameters,
  formatUnits,
  http,
  parseUnits,
  type Address,
  type ContractFunctionArgs,
  type PublicClient,
} from "viem";
import { poolSwapTestAbi } from "./abis/PoolSwapTest.js";
import {
  MUMB_DECIMALS,
  SWAP_GAS_LIMIT,
  USDC_DECIMALS,
  loadDeployment,
  rpcUrl,
  type PoolKeyJson,
} from "./config.js";

// ---- types ------------------------------------------------------------------

/** Output of the trader's full swap for a hint, or null if the simulation reverted. */
export type Simulate = (hint: bigint) => Promise<bigint | null>;

export interface BestHint {
  /** Aqua input amount to pass in hookData, in input-token base units. */
  hint: bigint;
  /** Output of the swap with hint 0 (pool only). */
  poolOnlyOut: bigint;
  /** Output of the swap with `hint`. */
  splitOut: bigint;
  /** hint / amountIn, a number in [0, 1] (rounded down to 6 decimals). */
  aquaShare: number;
}

export interface QuoteRequest {
  poolKey: PoolKeyJson;
  zeroForOne: boolean;
  /** Exact-input amount, base units. */
  amountIn: bigint;
  /** The trader's address; it must hold the input token and have approved the router. */
  from: Address;
}

export interface QuoterContext {
  client: Pick<PublicClient, "simulateContract">;
  swapRouter: Address;
  /** Called for every simulated point, in order of completion. */
  onPoint?: (hint: bigint, out: bigint | null) => void;
}

// ---- the search (pure) ------------------------------------------------------

const COARSE_STEPS = 10n; // 0%, 10%, ..., 100%
const REFINE_POINTS = 5n; // between the best two coarse points

/**
 * Simulates hints 0%..100% in 10% steps, then 5 evenly spaced points between the best
 * two usable ones, and returns the best. A reverted simulation is unusable: it is never
 * chosen and is not read as an output of zero. Ties go to the smaller hint (less Aqua
 * for the same output). Hint 0 reverting is an error: there is no pool-only baseline.
 */
export async function searchHint(amountIn: bigint, simulate: Simulate): Promise<BestHint> {
  if (amountIn <= 0n) throw new Error("amountIn must be positive");

  const results = new Map<bigint, bigint | null>();
  const run = async (hints: bigint[]) => {
    const fresh = [...new Set(hints)].filter((h) => !results.has(h));
    const outs = await Promise.all(fresh.map((h) => simulate(h)));
    fresh.forEach((h, i) => results.set(h, outs[i]!));
  };

  const coarse: bigint[] = [];
  for (let i = 0n; i <= COARSE_STEPS; i++) coarse.push((amountIn * i) / COARSE_STEPS);
  await run(coarse);

  const poolOnlyOut = results.get(0n);
  if (poolOnlyOut === null || poolOnlyOut === undefined) {
    throw new Error("the pool-only simulation (hint 0) reverted: no baseline to compare against");
  }

  const ranked = () =>
    [...results.entries()]
      .filter((e): e is [bigint, bigint] => e[1] !== null)
      .sort((a, b) => (a[1] === b[1] ? (a[0] < b[0] ? -1 : 1) : a[1] > b[1] ? -1 : 1));

  const top = ranked().slice(0, 2);
  if (top.length === 2) {
    const lo = top[0]![0] < top[1]![0] ? top[0]![0] : top[1]![0];
    const hi = top[0]![0] < top[1]![0] ? top[1]![0] : top[0]![0];
    const interior: bigint[] = [];
    for (let k = 1n; k <= REFINE_POINTS; k++) {
      const h = lo + ((hi - lo) * k) / (REFINE_POINTS + 1n);
      if (h > lo && h < hi) interior.push(h);
    }
    await run(interior);
  }

  const [hint, splitOut] = ranked()[0]!;
  return {
    hint,
    poolOnlyOut,
    splitOut,
    aquaShare: Number((hint * 1_000_000n) / amountIn) / 1e6,
  };
}

// ---- simulating on chain ----------------------------------------------------

// TickMath.MIN_SQRT_PRICE + 1 and MAX_SQRT_PRICE - 1: no price limit in practice.
const MIN_PRICE_LIMIT = 4295128740n;
const MAX_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341n;

const MASK128 = (1n << 128n) - 1n;

/** The output amount of a swap, from the packed BalanceDelta (amount0 high, amount1 low). */
export function decodeDelta(delta: bigint, zeroForOne: boolean): bigint {
  const amount0 = BigInt.asIntN(128, delta >> 128n);
  const amount1 = BigInt.asIntN(128, delta & MASK128);
  return zeroForOne ? amount1 : amount0;
}

const encodeHint = (hint: bigint) => encodeAbiParameters([{ type: "uint256" }], [hint]);

/** True when the failure is the node being unreachable, not the call reverting. */
function isTransportError(e: unknown): boolean {
  const err = e as { walk?: (fn: (x: unknown) => boolean) => unknown };
  return typeof err?.walk === "function"
    ? err.walk((x) => x instanceof HttpRequestError || x instanceof TimeoutError) !== null
    : false;
}

export function makeSimulate(req: QuoteRequest, ctx: QuoterContext): Simulate {
  return async (hint) => {
    try {
      const args: ContractFunctionArgs<typeof poolSwapTestAbi, "payable", "swap"> = [
        req.poolKey,
        {
          zeroForOne: req.zeroForOne,
          amountSpecified: -req.amountIn,
          sqrtPriceLimitX96: req.zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT,
        },
        { takeClaims: false, settleUsingBurn: false },
        encodeHint(hint),
      ];
      const { result } = await ctx.client.simulateContract({
        address: ctx.swapRouter,
        abi: poolSwapTestAbi,
        functionName: "swap",
        args,
        account: req.from,
        // The same explicit limit the real transaction uses (D-20).
        gas: SWAP_GAS_LIMIT,
      });
      const out = decodeDelta(result as bigint, req.zeroForOne);
      ctx.onPoint?.(hint, out);
      return out;
    } catch (e) {
      if (isTransportError(e)) throw e; // a dead node is not a reverted swap
      ctx.onPoint?.(hint, null);
      return null;
    }
  };
}

export async function bestHint(req: QuoteRequest, ctx?: QuoterContext): Promise<BestHint> {
  const c = ctx ?? defaultContext();
  return searchHint(req.amountIn, makeSimulate(req, c));
}

function defaultContext(): QuoterContext {
  const d = loadDeployment();
  return { client: createPublicClient({ transport: http(rpcUrl()) }), swapRouter: d.swapRouter };
}

// ---- CLI --------------------------------------------------------------------

export type Direction = "usdc-to-mumb" | "mumb-to-usdc";

export function parseCliArgs(argv: string[]): { amount: string; dir: Direction } {
  const get = (flag: string) => {
    const i = argv.indexOf(flag);
    return i >= 0 ? argv[i + 1] : undefined;
  };
  const amount = get("--amount");
  const dir = get("--dir");
  if (amount === undefined || !/^\d+(\.\d+)?$/.test(amount)) {
    throw new Error("--amount is required: a positive decimal such as 1000 or 2.5");
  }
  if (dir !== "usdc-to-mumb" && dir !== "mumb-to-usdc") {
    throw new Error("--dir is required: usdc-to-mumb or mumb-to-usdc");
  }
  return { amount, dir };
}

/** Human amount to base units of the INPUT token (USDC 6 decimals, MUMB 18). */
export function amountInRaw(amount: string, dir: Direction): bigint {
  return parseUnits(amount, dir === "usdc-to-mumb" ? USDC_DECIMALS : MUMB_DECIMALS);
}

/** v4 sorts currency0 < currency1 by address, so the direction follows the address order. */
export function zeroForOneFor(dir: Direction, usdc: Address, mumb: Address): boolean {
  const usdcIsCurrency0 = usdc.toLowerCase() < mumb.toLowerCase();
  return dir === "usdc-to-mumb" ? usdcIsCurrency0 : !usdcIsCurrency0;
}

async function main(): Promise<void> {
  const { amount, dir } = parseCliArgs(process.argv.slice(2));
  const d = loadDeployment();
  const zeroForOne = zeroForOneFor(dir, d.usdc, d.mumb);
  const amountIn = amountInRaw(amount, dir);
  const outDecimals = dir === "usdc-to-mumb" ? MUMB_DECIMALS : USDC_DECIMALS;
  const inDecimals = dir === "usdc-to-mumb" ? USDC_DECIMALS : MUMB_DECIMALS;
  const inSym = dir === "usdc-to-mumb" ? "USDC" : "MUMB";
  const outSym = dir === "usdc-to-mumb" ? "MUMB" : "USDC";

  const points = new Map<bigint, bigint | null>();
  const ctx: QuoterContext = {
    client: createPublicClient({ transport: http(rpcUrl()) }),
    swapRouter: d.swapRouter,
    onPoint: (h, o) => points.set(h, o),
  };
  console.log(`quoting ${amount} ${inSym} -> ${outSym} at gas limit ${SWAP_GAS_LIMIT}, as ${d.trader}`);
  const res = await bestHint({ poolKey: d.poolKey, zeroForOne, amountIn, from: d.trader }, ctx);

  const rows = [...points.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1));
  console.log(`${"share".padStart(8)} ${`hint (${inSym})`.padStart(22)} ${`out (${outSym})`.padStart(28)}`);
  for (const [h, o] of rows) {
    const share = `${(Number((h * 10_000n) / amountIn) / 100).toFixed(2)}%`;
    const out = o === null ? "reverted" : formatUnits(o, outDecimals);
    const mark = h === res.hint ? "  <- best" : "";
    console.log(`${share.padStart(8)} ${formatUnits(h, inDecimals).padStart(22)} ${out.padStart(28)}${mark}`);
  }
  console.log(`pool only : ${formatUnits(res.poolOnlyOut, outDecimals)} ${outSym}`);
  console.log(`best split: ${formatUnits(res.splitOut, outDecimals)} ${outSym}`);
  console.log(`hint      : ${res.hint} (${(res.aquaShare * 100).toFixed(2)}% to Aqua)`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e) => {
    console.error(e instanceof Error ? e.message : e);
    process.exit(1);
  });
}
