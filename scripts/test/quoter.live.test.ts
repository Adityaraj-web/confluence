// F07 live acceptance. Needs the anvil fork running and `forge script script/Setup.s.sol` done
// (deployments/local.json). It FAILS, not skips, when there is no anvil.
// Run: pnpm --dir scripts test:int
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  encodeAbiParameters,
  http,
  parseEventLogs,
  type Address,
  type ContractFunctionArgs,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { confluenceHookAbi } from "../src/abis/ConfluenceHook.js";
import { mockMumbAbi } from "../src/abis/MockMUMB.js";
import { poolManagerAbi } from "../src/abis/IPoolManager.js";
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

test("test_F07_live_realSwapMatchesQuote", async () => {
  // A REAL transaction from the trader at SWAP_GAS_LIMIT with the quoter's hint, inside an anvil
  // snapshot that is reverted afterwards. The quote must equal what the trader actually receives.
  const pk = process.env.TRADER_PRIVATE_KEY;
  assert.ok(pk, "TRADER_PRIVATE_KEY is not set: run `pnpm --dir scripts test:int` (it loads ../.env.example)");
  const account = privateKeyToAccount(pk as Hex);
  assert.equal(account.address.toLowerCase(), d.trader.toLowerCase(), "key does not belong to deployments trader");

  const dir = "usdc-to-mumb";
  const zeroForOne = zeroForOneFor(dir, d.usdc, d.mumb);
  const amountIn = amountInRaw("1000", dir);
  const wallet = createWalletClient({ account, transport: http(rpcUrl()) });
  const testClient = createTestClient({ mode: "anvil", transport: http(rpcUrl()) });
  const mumbOf = (who: Address) =>
    client.readContract({ address: d.mumb, abi: mockMumbAbi, functionName: "balanceOf", args: [who] });

  const snapshot = await testClient.snapshot();
  try {
    const { ctx } = recordingContext();
    const q = await bestHint({ poolKey: d.poolKey, zeroForOne, amountIn, from: d.trader }, ctx);
    const before = await mumbOf(d.trader);

    const args: ContractFunctionArgs<typeof poolSwapTestAbi, "payable", "swap"> = [
      d.poolKey,
      {
        zeroForOne,
        amountSpecified: -amountIn,
        sqrtPriceLimitX96: zeroForOne ? 4295128740n : 1461446703485210103287273052203988822378723970341n,
      },
      { takeClaims: false, settleUsingBurn: false },
      encodeAbiParameters([{ type: "uint256" }], [q.hint]),
    ];
    const txHash = await wallet.writeContract({
      address: d.swapRouter,
      abi: poolSwapTestAbi,
      functionName: "swap",
      args,
      gas: SWAP_GAS_LIMIT,
      chain: null,
    });
    const receipt = await client.waitForTransactionReceipt({ hash: txHash });
    assert.equal(receipt.status, "success");
    const received = (await mumbOf(d.trader)) - before;

    const fills = parseEventLogs({ abi: confluenceHookAbi, logs: receipt.logs, eventName: "AquaFill" });
    const skips = parseEventLogs({ abi: confluenceHookAbi, logs: receipt.logs, eventName: "AquaSkipped" });
    const swaps = parseEventLogs({ abi: poolManagerAbi, logs: receipt.logs, eventName: "Swap" });
    assert.equal(skips.length, 0, "Aqua was skipped");
    assert.equal(fills.length, 1, "expected exactly one AquaFill");
    assert.equal(swaps.length, 1, "expected exactly one pool Swap event");
    const fill = fills[0]!.args;
    // The pool leg's MUMB output, from the PoolManager's own Swap event (sign-agnostic).
    const abs = (x: bigint) => (x < 0n ? -x : x);
    const sw = swaps[0]!.args;
    const mumbIsCurrency0 = d.poolKey.currency0.toLowerCase() === d.mumb.toLowerCase();
    const poolLegMumb = abs(mumbIsCurrency0 ? sw.amount0 : sw.amount1);

    console.log(
      `# quoted splitOut ${q.splitOut}, received ${received}, hint ${q.hint}, ` +
        `AquaFill in ${fill.amountIn} out ${fill.amountOut}, pool leg out ${poolLegMumb}, gas used ${receipt.gasUsed}`,
    );
    assert.equal(received, q.splitOut, "trader's MUMB change must equal the quoted splitOut");
    assert.equal(fill.amountIn, q.hint, "AquaFill amountIn must equal the hint");
    assert.equal(fill.amountOut + poolLegMumb, q.splitOut, "Aqua leg + pool leg must equal the quoted splitOut");
  } finally {
    assert.equal(await testClient.revert({ id: snapshot }), undefined);
  }
});
