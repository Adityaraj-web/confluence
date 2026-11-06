// F07 quoter: unit tests. No chain needed; the simulator is a fake.
// Live acceptance (against anvil) is in quoter.live.test.ts.
import { test } from "node:test";
import assert from "node:assert/strict";
import { decodeAbiParameters, encodeAbiParameters, type Address } from "viem";
import {
  bestHint,
  decodeDelta,
  searchHint,
  parseCliArgs,
  zeroForOneFor,
  amountInRaw,
  type Simulate,
} from "../src/quoter.js";
import { SWAP_GAS_LIMIT } from "../src/config.js";

type Sim = Simulate;
const REVERT = null;

/** Wraps a curve into a Simulate that records every hint it was asked for. */
function recorder(curve: (hint: bigint) => bigint | null) {
  const seen = new Map<bigint, bigint | null>();
  const calls: bigint[] = [];
  const simulate: Sim = async (hint) => {
    calls.push(hint);
    const out = curve(hint);
    seen.set(hint, out);
    return out;
  };
  return { simulate, seen, calls };
}

/** A concave curve with its peak at `peak`. */
const peaked = (peak: bigint) => (h: bigint) => 10n ** 12n - (h - peak) * (h - peak);

test("test_F07_hintZeroEqualsPoolOnly", async () => {
  const r = recorder(peaked(3270n));
  const res = await searchHint(6000n, r.simulate);
  assert.equal(r.seen.has(0n), true, "hint 0 must be simulated");
  assert.equal(res.poolOnlyOut, r.seen.get(0n));
});

test("test_F07_chosenHintIsMaxOfAllSimulatedPoints", async () => {
  // A bumpy, non-concave curve (deterministic).
  const curve = (h: bigint) => ((h * 2654435761n) % 1_000_003n) + 1n;
  const r = recorder(curve);
  const res = await searchHint(1_000_000n, r.simulate);
  const outs = [...r.seen.values()].filter((v): v is bigint => v !== null);
  const max = outs.reduce((a, b) => (a > b ? a : b));
  assert.equal(res.splitOut, max);
  assert.equal(r.seen.get(res.hint), max);
});

test("test_F07_refinesWithFivePointsBetweenBestTwo", async () => {
  const r = recorder(peaked(3270n));
  const res = await searchHint(6000n, r.simulate);
  // 11 coarse points (0%..100%) + 5 interior points between 3000 and 3600.
  assert.equal(new Set(r.calls).size, 16);
  assert.equal(r.calls.length, 16, "no point is simulated twice");
  for (const h of [3100n, 3200n, 3300n, 3400n, 3500n]) assert.equal(r.seen.has(h), true, `refine ${h}`);
  assert.equal(res.hint, 3300n);
});

test("test_F07_revertedSimulationIsUnusable", async () => {
  // The two best coarse points (3000, 3600) revert. They must not be returned
  // and must not be read as an output of zero.
  const base = peaked(3270n);
  const r = recorder((h) => (h === 3000n || h === 3600n ? REVERT : base(h)));
  const res = await searchHint(6000n, r.simulate);
  assert.notEqual(res.hint, 3000n);
  assert.notEqual(res.hint, 3600n);
  const usable = [...r.seen.values()].filter((v): v is bigint => v !== null);
  assert.equal(res.splitOut, usable.reduce((a, b) => (a > b ? a : b)));
  // Refinement runs between the best two USABLE coarse points (2400 and 4200).
  assert.equal(r.seen.has(3300n), true);
  assert.equal(res.hint, 3300n);
});

test("test_F07_throwsWhenHintZeroReverts", async () => {
  const r = recorder((h) => (h === 0n ? REVERT : 5n));
  await assert.rejects(() => searchHint(6000n, r.simulate), /pool-only/i);
});

test("test_F07_allSplitHintsRevertReturnsHintZero", async () => {
  const r = recorder((h) => (h === 0n ? 100n : REVERT));
  const res = await searchHint(6000n, r.simulate);
  assert.equal(res.hint, 0n);
  assert.equal(res.splitOut, res.poolOnlyOut);
  assert.equal(res.aquaShare, 0);
});

test("test_F07_tieBreaksToSmallerHint", async () => {
  const r = recorder(() => 777n);
  const res = await searchHint(6000n, r.simulate);
  assert.equal(res.hint, 0n);
});

test("test_F07_hundredPercentNeverExceedsAmountIn", async () => {
  for (const amountIn of [1n, 7n, 999n, 1_000_000_000n, 10n ** 21n + 1n]) {
    const r = recorder((h) => h + 1n); // increasing: the top of the range is best
    const res = await searchHint(amountIn, r.simulate);
    assert.equal(r.seen.has(amountIn), true, `100% point simulated for ${amountIn}`);
    for (const h of r.calls) assert.equal(h <= amountIn, true, `hint ${h} <= ${amountIn}`);
    assert.equal(res.hint <= amountIn, true);
    assert.equal(res.hint, amountIn);
  }
});

test("test_F07_rejectsZeroAmount", async () => {
  await assert.rejects(() => searchHint(0n, async () => 1n), /amountIn/);
});

test("test_F07_aquaShareIsHintOverAmount", async () => {
  const r = recorder(peaked(3270n));
  const res = await searchHint(6000n, r.simulate);
  assert.ok(Math.abs(res.aquaShare - Number(res.hint) / 6000) < 1e-6);
});

// ---- bestHint with a fake viem client -------------------------------------

// Placeholder addresses: unit tests never touch a chain (rules: no inlined real addresses).
const USDC = "0x00000000000000000000000000000000000000c1" as Address;
const MUMB = "0x00000000000000000000000000000000000000c2" as Address;
const [C0, C1] = USDC.toLowerCase() < MUMB.toLowerCase() ? [USDC, MUMB] : [MUMB, USDC];
const poolKey = { currency0: C0, currency1: C1, fee: 3000, tickSpacing: 60, hooks: MUMB };
const FROM = "0x00000000000000000000000000000000000000f1" as Address;
const ROUTER = "0x00000000000000000000000000000000000000a1" as Address;

const MASK = (1n << 128n) - 1n;
const pack = (a0: bigint, a1: bigint) => (a0 << 128n) | (a1 & MASK);

function fakeClient(curve: (hint: bigint) => bigint | null, zeroForOne: boolean, amountIn: bigint) {
  const calls: any[] = [];
  return {
    calls,
    client: {
      simulateContract: async (req: any) => {
        calls.push(req);
        const hookData: `0x${string}` = req.args[3];
        const hint = hookData === "0x" ? 0n : (decodeAbiParameters([{ type: "uint256" }], hookData)[0] as bigint);
        const out = curve(hint);
        if (out === null) throw new Error("execution reverted");
        return { result: zeroForOne ? pack(-amountIn, out) : pack(out, -amountIn) };
      },
    },
  };
}

test("test_F07_decodeDeltaReadsOutputAmount", () => {
  assert.equal(decodeDelta(pack(-1000n, 984n), true), 984n);
  assert.equal(decodeDelta(pack(984n, -1000n), false), 984n);
});

test("test_F07_simulatesAtExplicitGasLimit", async () => {
  assert.equal(SWAP_GAS_LIMIT, 1_500_000n);
  const f = fakeClient(peaked(3270n), true, 6000n);
  await bestHint({ poolKey, zeroForOne: true, amountIn: 6000n, from: FROM }, { client: f.client as any, swapRouter: ROUTER });
  assert.equal(f.calls.length, 16);
  for (const c of f.calls) {
    assert.equal(c.gas, SWAP_GAS_LIMIT);
    assert.equal(c.account, FROM);
    assert.equal(c.address, ROUTER);
  }
});

test("test_F07_bestHintReturnsSpecShape", async () => {
  const f = fakeClient(peaked(3270n), false, 6000n);
  const res = await bestHint({ poolKey, zeroForOne: false, amountIn: 6000n, from: FROM }, { client: f.client as any, swapRouter: ROUTER });
  assert.deepEqual(Object.keys(res).sort(), ["aquaShare", "hint", "poolOnlyOut", "splitOut"]);
  assert.equal(res.hint, 3300n);
  assert.equal(res.splitOut > res.poolOnlyOut, true);
});

test("test_F07_hintIsAbiEncodedUint256", async () => {
  const f = fakeClient(peaked(3270n), true, 6000n);
  await bestHint({ poolKey, zeroForOne: true, amountIn: 6000n, from: FROM }, { client: f.client as any, swapRouter: ROUTER });
  const hookData: `0x${string}` = f.calls[1].args[3];
  assert.equal(hookData, encodeAbiParameters([{ type: "uint256" }], [600n]));
});

// ---- CLI ------------------------------------------------------------------

test("test_F07_cliParsesAmountAndDirection", () => {
  assert.deepEqual(parseCliArgs(["--amount", "1000", "--dir", "usdc-to-mumb"]), { amount: "1000", dir: "usdc-to-mumb" });
  assert.deepEqual(parseCliArgs(["--dir", "mumb-to-usdc", "--amount", "2.5"]), { amount: "2.5", dir: "mumb-to-usdc" });
  assert.throws(() => parseCliArgs(["--dir", "usdc-to-mumb"]), /--amount/);
  assert.throws(() => parseCliArgs(["--amount", "1", "--dir", "sideways"]), /--dir/);
  assert.throws(() => parseCliArgs(["--amount", "abc", "--dir", "usdc-to-mumb"]), /--amount/);
});

test("test_F07_cliAmountUsesInputTokenDecimals", () => {
  assert.equal(amountInRaw("1000", "usdc-to-mumb"), 1_000_000_000n); // USDC, 6 decimals
  assert.equal(amountInRaw("1000", "mumb-to-usdc"), 10n ** 21n); // MUMB, 18 decimals
  assert.equal(amountInRaw("0.5", "usdc-to-mumb"), 500_000n);
});

test("test_F07_zeroForOneFollowsAddressOrder", () => {
  const lo = "0x0000000000000000000000000000000000000001" as Address;
  const hi = "0xF000000000000000000000000000000000000001" as Address;
  assert.equal(zeroForOneFor("usdc-to-mumb", lo, hi), true); // USDC is currency0
  assert.equal(zeroForOneFor("mumb-to-usdc", lo, hi), false);
  assert.equal(zeroForOneFor("usdc-to-mumb", hi, lo), false); // MUMB is currency0
  assert.equal(zeroForOneFor("mumb-to-usdc", hi, lo), true);
});
