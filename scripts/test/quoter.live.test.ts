// F07 live acceptance. Needs the anvil fork running and `forge script script/Setup.s.sol` done
// (deployments/local.json). It FAILS, not skips, when there is no anvil.
// Run: pnpm --dir scripts test:int
import { test } from "node:test";
import assert from "node:assert/strict";
import { createPublicClient, encodeAbiParameters, http, type ContractFunctionArgs } from "viem";
import { poolSwapTestAbi } from "../src/abis/PoolSwapTest.js";
import { SWAP_GAS_LIMIT, loadDeployment, rpcUrl } from "../src/config.js";
import { amountInRaw, bestHint, decodeDelta, zeroForOneFor, type QuoterContext } from "../src/quoter.js";

const d = loadDeployment();
const client = createPublicClient({ transport: http(rpcUrl()) });

function recordingContext() {
  const points = new Map<bigint, bigint | null>();
  const ctx: QuoterContext = { client, swapRouter: d.swapRouter, onPoint: (h, o) => points.set(h, o) };
  return { ctx, points };
}

test("test_F07_live_splitBeatsPoolOnly", async () => {
  const dir = "usdc-to-mumb";
  const zeroForOne = zeroForOneFor(dir, d.usdc, d.mumb);
  const { ctx } = recordingContext();
  const res = await bestHint({ poolKey: d.poolKey, zeroForOne, amountIn: amountInRaw("1000", dir), from: d.trader }, ctx);
  console.log(`# pool-only ${res.poolOnlyOut}, split ${res.splitOut}, hint ${res.hint} (${res.aquaShare})`);
  assert.equal(res.splitOut > res.poolOnlyOut, true);
  assert.equal(res.hint > 0n, true);
});

test("test_F07_live_hintZeroEqualsPoolOnlyPath", async () => {
  // Hint 0 (encoded) and empty hookData both take the pool-only path in the hook.
  const dir = "usdc-to-mumb";
  const zeroForOne = zeroForOneFor(dir, d.usdc, d.mumb);
  const amountIn = amountInRaw("1000", dir);
  const { ctx } = recordingContext();
  const res = await bestHint({ poolKey: d.poolKey, zeroForOne, amountIn, from: d.trader }, ctx);

  const empty = await client.simulateContract({
    address: d.swapRouter,
    abi: poolSwapTestAbi,
    functionName: "swap",
    args: [
      d.poolKey,
      {
        zeroForOne,
        amountSpecified: -amountIn,
        sqrtPriceLimitX96: zeroForOne ? 4295128740n : 1461446703485210103287273052203988822378723970341n,
      },
      { takeClaims: false, settleUsingBurn: false },
      "0x",
    ],
    account: d.trader,
    gas: SWAP_GAS_LIMIT,
  });
  assert.equal(decodeDelta(empty.result as bigint, zeroForOne), res.poolOnlyOut);
});

test("test_F07_live_gasLimitChangesTheSplit", async () => {
  // D-20: below a gas limit of 396,526 the hook skips Aqua. The same hint therefore gives the
  // pool-only output at a low limit and the split output at SWAP_GAS_LIMIT.
  const dir = "usdc-to-mumb";
  const zeroForOne = zeroForOneFor(dir, d.usdc, d.mumb);
  const amountIn = amountInRaw("1000", dir);
  const { ctx } = recordingContext();
  const res = await bestHint({ poolKey: d.poolKey, zeroForOne, amountIn, from: d.trader }, ctx);

  const at = async (gas: bigint) => {
    const args: ContractFunctionArgs<typeof poolSwapTestAbi, "payable", "swap"> = [
      d.poolKey,
      {
        zeroForOne,
        amountSpecified: -amountIn,
        sqrtPriceLimitX96: zeroForOne ? 4295128740n : 1461446703485210103287273052203988822378723970341n,
      },
      { takeClaims: false, settleUsingBurn: false },
      encodeAbiParameters([{ type: "uint256" }], [res.hint]),
    ];
    const r = await client.simulateContract({
      address: d.swapRouter,
      abi: poolSwapTestAbi,
      functionName: "swap",
      args,
      account: d.trader,
      gas,
    });
    return decodeDelta(r.result as bigint, zeroForOne);
  };
  assert.equal(await at(SWAP_GAS_LIMIT), res.splitOut);
  assert.equal(await at(300_000n), res.poolOnlyOut);
});

test("test_F07_live_chosenHintIsMaxOfAllSimulatedPoints", async () => {
  const dir = "usdc-to-mumb";
  const zeroForOne = zeroForOneFor(dir, d.usdc, d.mumb);
  const { ctx, points } = recordingContext();
  const res = await bestHint({ poolKey: d.poolKey, zeroForOne, amountIn: amountInRaw("1000", dir), from: d.trader }, ctx);
  const outs = [...points.values()].filter((v): v is bigint => v !== null);
  assert.equal(outs.length >= 11, true);
  assert.equal(res.splitOut, outs.reduce((a, b) => (a > b ? a : b)));
  assert.equal(points.get(res.hint), res.splitOut);
});

test("test_F07_live_mumbToUsdcWorks", async () => {
  const dir = "mumb-to-usdc";
  const zeroForOne = zeroForOneFor(dir, d.usdc, d.mumb);
  const amountIn = amountInRaw("1000", dir);
  const { ctx } = recordingContext();
  const res = await bestHint({ poolKey: d.poolKey, zeroForOne, amountIn, from: d.trader }, ctx);
  assert.equal(res.splitOut > res.poolOnlyOut, true);
  assert.equal(res.hint > 0n && res.hint <= amountIn, true);
});
