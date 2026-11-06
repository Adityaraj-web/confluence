// Browser-safe copy of the off-chain quoter in scripts/src/quoter.ts @6929941 (searchHint, makeSimulate, decodeDelta,
// amountInRaw, zeroForOneFor). The original imports node:url and config.ts (node:fs), so it cannot run in a browser.
// test_F10_searchHintEqualsScripts_* compare this copy with the original on fixed fixtures. Keep them in step.
import {
  HttpRequestError,
  TimeoutError,
  encodeAbiParameters,
  parseUnits,
  type Address,
  type ContractFunctionArgs,
  type PublicClient,
} from "viem";
import { poolSwapTestAbi } from "../../../scripts/src/abis/PoolSwapTest.ts";
import { MAX_PRICE_LIMIT, MIN_PRICE_LIMIT, MUMB_DECIMALS, SWAP_GAS_LIMIT, USDC_DECIMALS } from "./constants.ts";
import type { Direction, PoolKeyJson } from "./types.ts";

export type Simulate = (hint: bigint) => Promise<bigint | null>;

export interface BestHint {
  hint: bigint;
  poolOnlyOut: bigint;
  splitOut: bigint;
  aquaShare: number;
}

export interface QuoteRequest {
  poolKey: PoolKeyJson;
  zeroForOne: boolean;
  amountIn: bigint;
  from: Address;
}

export interface QuoterContext {
  client: Pick<PublicClient, "simulateContract">;
  swapRouter: Address;
  onPoint?: (hint: bigint, out: bigint | null) => void;
}

const COARSE_STEPS = 10n;
const REFINE_POINTS = 5n;

/**
 * Simulates hints 0%..100% in 10% steps, then 5 evenly spaced points between the best
 * two usable ones, and returns the best. A reverted simulation is unusable. Ties go to the smaller hint.
 * Hint 0 reverting is an error: there is no pool-only baseline.
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
  return { hint, poolOnlyOut, splitOut, aquaShare: Number((hint * 1_000_000n) / amountIn) / 1e6 };
}

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
        gas: SWAP_GAS_LIMIT, // the same explicit limit the real transaction uses (D-20)
      });
      const out = decodeDelta(result as bigint, req.zeroForOne);
      ctx.onPoint?.(hint, out);
      return out;
    } catch (e) {
      if (isTransportError(e)) throw e;
      ctx.onPoint?.(hint, null);
      return null;
    }
  };
}

export async function bestHint(req: QuoteRequest, ctx: QuoterContext): Promise<BestHint> {
  return searchHint(req.amountIn, makeSimulate(req, ctx));
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
