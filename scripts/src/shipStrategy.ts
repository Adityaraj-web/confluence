// F09 step 6 of ARCHITECTURE section 2, as Priya: approve Aqua, then ship her strategy with the canonical
// router as the Aqua `app`. It first rebuilds the order with the 1inch SDK and refuses to ship unless the bytes
// equal what Setup.s.sol registered in the hook (`orderHex` in deployments/local.json, and `hook.orderOf`).
// Run: pnpm --dir scripts ship      (after `forge script script/Setup.s.sol`; `deploy` does both)
import { pathToFileURL } from "node:url";
import {
  createPublicClient,
  createWalletClient,
  encodeAbiParameters,
  formatUnits,
  http,
  keccak256,
  maxUint256,
  parseEventLogs,
  type Address,
  type ContractFunctionArgs,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { aquaAbi } from "./abis/IAqua.js";
import { confluenceHookAbi } from "./abis/ConfluenceHook.js";
import { mockMumbAbi } from "./abis/MockMUMB.js";
import { MUMB_DECIMALS, USDC_DECIMALS, loadDeployment, rpcUrl, type Deployment } from "./config.js";
import { buildBandArgs, buildBandProgram, buildOrderEncoded } from "./strategy.js";

/** What Priya ships: the same amounts as Setup used to (ForkBase / PoolBase / ConfluenceBase). */
export const SHIPPED_MUMB = 100_000n * 10n ** BigInt(MUMB_DECIMALS);
export const SHIPPED_USDC = 100_000n * 10n ** BigInt(USDC_DECIMALS);

// ---- pure helpers -------------------------------------------------------------

/** Index of the first byte where two hex strings differ, or null if they are equal. A prefix differs at its end. */
export function firstByteDifference(a: Hex, b: Hex): number | null {
  const x = a.slice(2).toLowerCase();
  const y = b.slice(2).toLowerCase();
  if (x === y) return null;
  const n = Math.min(x.length, y.length) / 2;
  for (let i = 0; i < n; i++) {
    if (x.slice(2 * i, 2 * i + 2) !== y.slice(2 * i, 2 * i + 2)) return i;
  }
  return n;
}

/** Throws with the first differing byte and both lengths, so a mismatch can be diagnosed from the message. */
export function assertSameBytes(label: string, got: Hex, want: Hex): void {
  const at = firstByteDifference(got, want);
  if (at === null) return;
  const byteAt = (h: Hex) => {
    const s = h.slice(2 + 2 * at, 4 + 2 * at);
    return s === "" ? "(end)" : `0x${s.toLowerCase()}`;
  };
  throw new Error(
    `${label}: first difference at byte ${at} (got ${byteAt(got)}, want ${byteAt(want)}); ` +
      `lengths ${(got.length - 2) / 2} and ${(want.length - 2) / 2}`,
  );
}

const orderTuple = [
  {
    type: "tuple",
    components: [
      { name: "maker", type: "address" },
      { name: "traits", type: "uint256" },
      { name: "data", type: "bytes" },
    ],
  },
] as const;

export const poolKeyTuple = [
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

/** The order exactly as the TS side builds it from the deployment (no chain access). */
export function tsOrderFor(d: Deployment): Hex {
  const bandArgs = buildBandArgs(d.poolManager, d.poolKey, d.bandBps);
  return buildOrderEncoded(d.maker, buildBandProgram(BigInt(d.feeE9), d.band, bandArgs));
}

// ---- the ship -----------------------------------------------------------------

export interface ShipResult {
  strategyHash: Hex;
  shipTx: Hex;
}

export async function shipStrategy(priyaPrivateKey: Hex, d: Deployment = loadDeployment()): Promise<ShipResult> {
  const account = privateKeyToAccount(priyaPrivateKey);
  if (account.address.toLowerCase() !== d.maker.toLowerCase()) {
    throw new Error(`PRIYA_PRIVATE_KEY is ${account.address}, but the deployment's maker is ${d.maker}`);
  }
  const transport = http(rpcUrl());
  const pub = createPublicClient({ transport });
  const wallet = createWalletClient({ account, transport });

  // 1. The byte check: nothing is sent unless the TS order is the order the hook has.
  const tsOrder = tsOrderFor(d);
  assertSameBytes("TS order vs orderHex in local.json", tsOrder, d.orderHex);
  const registered = await pub.readContract({
    address: d.hook,
    abi: confluenceHookAbi,
    functionName: "orderOf",
    args: [keccak256(encodeAbiParameters(poolKeyTuple, [d.poolKey]))],
  });
  assertSameBytes("TS order vs hook.orderOf", tsOrder, encodeAbiParameters(orderTuple, [registered]));
  if (keccak256(tsOrder) !== d.expectedStrategyHash) {
    throw new Error(`keccak256(TS order) ${keccak256(tsOrder)} != expectedStrategyHash ${d.expectedStrategyHash}`);
  }
  console.log(`byte check: TS order == orderHex == hook.orderOf (${(tsOrder.length - 2) / 2} bytes)`);

  // 2. Not shipped already: Aqua refuses a second ship of the same bytes, and a clear error beats a revert.
  const [, tokensCount] = await pub.readContract({
    address: d.aqua,
    abi: aquaAbi,
    functionName: "rawBalances",
    args: [d.maker, d.swapVmRouter, d.expectedStrategyHash, d.mumb],
  });
  if (tokensCount !== 0) {
    throw new Error(`strategy ${d.expectedStrategyHash} is already shipped or docked: start from a fresh anvil`);
  }

  // 3. Priya approves Aqua once for both tokens. Both are plain ERC-20s, so one ABI's `approve` serves both.
  for (const token of [d.mumb, d.usdc] as Address[]) {
    const tx = await wallet.writeContract({
      address: token,
      abi: mockMumbAbi,
      functionName: "approve",
      args: [d.aqua, maxUint256],
      chain: null,
    });
    const r = await pub.waitForTransactionReceipt({ hash: tx });
    if (r.status !== "success") throw new Error(`approve ${token} reverted (${tx})`);
    console.log(`approved Aqua for ${token} (tx ${tx})`);
  }

  // 4. Ship, with the canonical router as the Aqua app.
  const shipArgs: ContractFunctionArgs<typeof aquaAbi, "nonpayable", "ship"> = [
    d.swapVmRouter,
    tsOrder,
    [d.mumb, d.usdc],
    [SHIPPED_MUMB, SHIPPED_USDC],
  ];
  const shipTx = await wallet.writeContract({
    address: d.aqua,
    abi: aquaAbi,
    functionName: "ship",
    args: shipArgs,
    chain: null,
  });
  const receipt = await pub.waitForTransactionReceipt({ hash: shipTx });
  if (receipt.status !== "success") throw new Error(`ship reverted (${shipTx})`);

  // 5. The Shipped event must carry the hash Setup computed.
  const shipped = parseEventLogs({ abi: aquaAbi, eventName: "Shipped", logs: receipt.logs });
  if (shipped.length !== 1) throw new Error(`expected 1 Shipped event, found ${shipped.length} (${shipTx})`);
  const { strategyHash, maker, app } = shipped[0]!.args;
  if (strategyHash !== d.expectedStrategyHash) {
    throw new Error(`Shipped strategyHash ${strategyHash} != expectedStrategyHash ${d.expectedStrategyHash}`);
  }
  if (maker.toLowerCase() !== d.maker.toLowerCase() || app.toLowerCase() !== d.swapVmRouter.toLowerCase()) {
    throw new Error(`Shipped event maker/app are ${maker}/${app}, want ${d.maker}/${d.swapVmRouter}`);
  }

  // 6. Aqua now holds her virtual balances.
  const balance = async (token: Address) =>
    (
      await pub.readContract({
        address: d.aqua,
        abi: aquaAbi,
        functionName: "rawBalances",
        args: [d.maker, d.swapVmRouter, strategyHash, token],
      })
    )[0];
  const [vMumb, vUsdc] = [await balance(d.mumb), await balance(d.usdc)];
  if (vMumb !== SHIPPED_MUMB || vUsdc !== SHIPPED_USDC) {
    throw new Error(`virtual balances ${vMumb} MUMB / ${vUsdc} USDC, want ${SHIPPED_MUMB} / ${SHIPPED_USDC}`);
  }
  console.log(`Shipped strategyHash ${strategyHash} == expectedStrategyHash`);
  console.log(
    `Priya's Aqua balances: ${formatUnits(vMumb, MUMB_DECIMALS)} MUMB, ${formatUnits(vUsdc, USDC_DECIMALS)} USDC (ship tx ${shipTx})`,
  );
  return { strategyHash, shipTx };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const pk = process.env.PRIYA_PRIVATE_KEY;
  if (!pk || !/^0x[0-9a-fA-F]{64}$/.test(pk)) {
    console.error("PRIYA_PRIVATE_KEY is missing or not a 32-byte hex key (it is in .env.example)");
    process.exit(1);
  }
  shipStrategy(pk as Hex).catch((e) => {
    console.error(e instanceof Error ? e.message : e);
    process.exit(1);
  });
}
