// F10 decode tests: the web copies equal scripts/src/demo.ts on the same inputs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { encodeAbiParameters, encodeErrorResult, encodeEventTopics, type Address, type Hex } from "viem";
import { confluenceHookAbi } from "../../scripts/src/abis/ConfluenceHook.ts";
import { poolPriceBandExtructionAbi } from "../../scripts/src/abis/PoolPriceBandExtruction.ts";
import { decodeSkipReason as scriptsDecode, legsFromLogs as scriptsLegs } from "../../scripts/src/demo.ts";
import { decodeBandExceeded, decodeSkipReason, legsFromLogs } from "../src/lib/decode.ts";

const exceeded = (exec: bigint, pool: bigint, band: number): Hex =>
  encodeErrorResult({ abi: poolPriceBandExtructionAbi, errorName: "PoolPriceBandExceeded", args: [exec, pool, band] });

test("test_F10_decodeSkipReasonEqualsScripts", () => {
  const cases: Hex[] = [
    exceeded(1_031_400n, 1_000_000n, 200),
    encodeErrorResult({ abi: confluenceHookAbi, errorName: "InsufficientGas", args: [123n] }),
    encodeErrorResult({ abi: confluenceHookAbi, errorName: "NoOrder" }),
    "0x",
    "0xdeadbeef0000",
    "0x12",
  ];
  for (const c of cases) assert.equal(decodeSkipReason(c), scriptsDecode(c));
  assert.equal(
    decodeSkipReason(exceeded(1_031_400n, 1_000_000n, 200)),
    "PoolPriceBandExceeded(execX96=1031400, poolX96=1000000, bandBps=200): fill price 3.14% off the pool price, band 2.00%",
  );
});

test("test_F10_decodeBandExceeded", () => {
  assert.deepEqual(decodeBandExceeded(exceeded(1_031_400n, 1_000_000n, 200)), { exec: 1_031_400n, pool: 1_000_000n, bandBps: 200 });
  assert.equal(decodeBandExceeded("0x"), null);
  assert.equal(decodeBandExceeded(encodeErrorResult({ abi: confluenceHookAbi, errorName: "NoOrder" })), null);
});

const HOOK: Address = "0x00000000000000000000000000000000000000a1";
const OTHER: Address = "0x00000000000000000000000000000000000000b2";
const POOL_ID: Hex = `0x${"11".repeat(32)}`;
const fakeLog = (address: Address, topics: readonly unknown[], data: Hex) =>
  ({ address, topics, data, blockNumber: 1n, transactionHash: `0x${"22".repeat(32)}`, logIndex: 0, removed: false }) as never;

test("test_F10_legsFromLogsEqualsScripts", () => {
  const maker: Address = "0x00000000000000000000000000000000000000f1";
  const fillTopics = encodeEventTopics({ abi: confluenceHookAbi, eventName: "AquaFill", args: { poolId: POOL_ID, maker } });
  const fillData = encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [550_000_000n, 545n]);
  const skipTopics = encodeEventTopics({ abi: confluenceHookAbi, eventName: "AquaSkipped", args: { poolId: POOL_ID } });
  const skipData = encodeAbiParameters([{ type: "bytes" }], ["0xabcd"]);
  const sets = [
    [fakeLog(HOOK, fillTopics, fillData)],
    [fakeLog(HOOK, skipTopics, skipData)],
    [fakeLog(OTHER, fillTopics, fillData)],
    [] as never[],
  ];
  for (const logs of sets) assert.deepEqual(legsFromLogs(logs, HOOK), scriptsLegs(logs, HOOK));
  assert.deepEqual(legsFromLogs([fakeLog(HOOK, fillTopics, fillData)], HOOK), { fill: { amountIn: 550_000_000n, amountOut: 545n } });
  assert.throws(() => legsFromLogs([fakeLog(HOOK, fillTopics, fillData), fakeLog(HOOK, fillTopics, fillData)], HOOK), /more than one AquaFill/);
});
