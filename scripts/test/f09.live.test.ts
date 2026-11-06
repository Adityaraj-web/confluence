// F09 live tests. Need the anvil fork running. They FAIL, not skip, without it.
// Run: node --env-file=../.env.example --env-file-if-exists=../.env --import tsx --test test/f09.live.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { createPublicClient, http, type Hex } from "viem";
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
