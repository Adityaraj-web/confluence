// Copies of scripts/src/demo.ts @eb8522b: decodeSkipReason, legsFromLogs. decodeBandExceeded is new (gap 5):
// the Guard screen needs the numbers, not the sentence.
import { decodeErrorResult, parseEventLogs, type Address, type Hex, type parseEventLogs as ParseEventLogs } from "viem";
import { confluenceHookAbi } from "../../../scripts/src/abis/ConfluenceHook.ts";
import { poolPriceBandExtructionAbi } from "../../../scripts/src/abis/PoolPriceBandExtruction.ts";
import { percent } from "./format.ts";

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

/** The numbers inside a PoolPriceBandExceeded reason, or null for any other reason. */
export function decodeBandExceeded(reason: Hex): { exec: bigint; pool: bigint; bandBps: number } | null {
  if (reason === "0x") return null;
  try {
    const { errorName, args } = decodeErrorResult({ abi: REASON_ABI, data: reason });
    if (errorName !== "PoolPriceBandExceeded") return null;
    const [exec, pool, bandBps] = (args ?? []) as unknown as [bigint, bigint, number];
    return { exec, pool, bandBps };
  } catch {
    return null;
  }
}

/** The hook's own events in a receipt's logs. Other contracts' logs are ignored. */
export function legsFromLogs(
  logs: readonly Parameters<typeof ParseEventLogs>[0]["logs"][number][],
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
