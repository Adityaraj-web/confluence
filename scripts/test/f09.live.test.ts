// F09 live tests. Need the anvil fork running. They FAIL, not skip, without it.
// Run: node --env-file=../.env.example --env-file-if-exists=../.env --import tsx --test test/f09.live.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { createPublicClient, http, type ContractFunctionArgs, type Hex } from "viem";
import { rpcUrl } from "../src/config.js";

const client = createPublicClient({ transport: http(rpcUrl()) });

const snapshot = () => client.request({ method: "evm_snapshot" } as never) as Promise<Hex>;
const revertTo = (id: Hex) => client.request({ method: "evm_revert", params: [id] } as never) as Promise<boolean>;
const mine = () => client.request({ method: "evm_mine", params: [] } as never);

// The demo must start both runs from identical state, so it needs to know how anvil's snapshot ids
// behave. Belief to check (PLAN item 5): a revert consumes the id, so a second revert to it fails and
// the demo must snapshot again straight after every revert.
test("test_F09_live_snapshotRevertIsReusableAfterResnapshot", async () => {
  const start = await client.getBlockNumber({ cacheTime: 0 });
  const s0 = await snapshot();

  await mine();
  assert.equal(await client.getBlockNumber({ cacheTime: 0 }), start + 1n);

  assert.equal(await revertTo(s0), true, "first revert to a fresh id succeeds");
  assert.equal(await client.getBlockNumber({ cacheTime: 0 }), start, "revert restores the block number");

  // Second revert to the same id: single-use means it fails (returns false).
  assert.equal(await revertTo(s0), false, "the id is consumed by the first revert");

  // So re-snapshot straight after the revert, and that new id works.
  const s1 = await snapshot();
  await mine();
  assert.equal(await revertTo(s1), true, "a re-taken snapshot reverts");
  assert.equal(await client.getBlockNumber({ cacheTime: 0 }), start);
});

// ---- step 2: the TS-built order is byte-equal to the one StrategyLib built and Setup registered ----

import { encodeAbiParameters, keccak256 } from "viem";
import { confluenceHookAbi } from "../src/abis/ConfluenceHook.js";
import { poolPriceBandExtructionAbi } from "../src/abis/PoolPriceBandExtruction.js";
import { loadDeployment } from "../src/config.js";
import { FEE_0_30_PCT, buildBandArgs, buildBandProgram, buildOrderEncoded } from "../src/strategy.js";

const POOL_MANAGER = "0x000000000004444c5dc75cB358380D2e3dE08A90" as const;
const BAND_BPS = 200; // Setup.s.sol BAND_BPS

const poolKeyAbi = [
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

test("test_F09_live_bandArgsEqualContractBuild", async () => {
  const d = loadDeployment();
  const args: ContractFunctionArgs<typeof poolPriceBandExtructionAbi, "pure", "build"> = [
    POOL_MANAGER,
    d.poolKey,
    BAND_BPS,
  ];
  const onChain = await client.readContract({
    address: d.band,
    abi: poolPriceBandExtructionAbi,
    functionName: "build",
    args,
  });
  assert.equal(buildBandArgs(POOL_MANAGER, d.poolKey, BAND_BPS), onChain);
});

test("test_F09_live_tsOrderEqualsRegisteredOrder", async () => {
  const d = loadDeployment();
  const poolId = keccak256(encodeAbiParameters(poolKeyAbi, [d.poolKey]));
  const registered = await client.readContract({
    address: d.hook,
    abi: confluenceHookAbi,
    functionName: "orderOf",
    args: [poolId],
  });
  assert.equal(registered.maker.toLowerCase(), d.maker.toLowerCase(), "an order is registered for Priya");

  const bandArgs = buildBandArgs(POOL_MANAGER, d.poolKey, BAND_BPS);
  const tsOrder = buildOrderEncoded(d.maker, buildBandProgram(FEE_0_30_PCT, d.band, bandArgs));

  const registeredEncoded = encodeAbiParameters(
    [{ type: "tuple", components: [{ name: "maker", type: "address" }, { name: "traits", type: "uint256" }, { name: "data", type: "bytes" }] }],
    [registered],
  );
  console.log(`# registered traits ${registered.traits}, data ${registered.data.length / 2 - 1} bytes`);
  assert.equal(tsOrder, registeredEncoded);
  // Aqua keys a strategy by keccak256 of the order, so equal bytes mean the same strategy hash.
  assert.equal(keccak256(tsOrder), d.strategyHash);
});
