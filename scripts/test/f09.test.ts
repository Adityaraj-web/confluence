// F09 unit tests: no chain needed. Run: pnpm --dir scripts test
import { test } from "node:test";
import assert from "node:assert/strict";
import { hexToBytes, keccak256, type Address, type Hex } from "viem";
import { FEE_0_30_PCT, buildBandArgs, buildBandProgram, buildOrderEncoded } from "../src/strategy.js";
import type { PoolKeyJson } from "../src/config.js";

const POOL_MANAGER: Address = "0x00000000000000000000000000000000000000b1";
const BAND: Address = "0x00000000000000000000000000000000000000b2";
const MAKER: Address = "0x00000000000000000000000000000000000000f1";
const KEY: PoolKeyJson = {
  currency0: "0x00000000000000000000000000000000000000c1",
  currency1: "0x00000000000000000000000000000000000000c2",
  fee: 3000,
  tickSpacing: 60,
  hooks: "0x00000000000000000000000000000000000000c0",
};

const strip = (h: Hex) => h.slice(2).toLowerCase();

test("test_F09_bandArgsLayout", () => {
  const args = buildBandArgs(POOL_MANAGER, KEY, 200);
  assert.equal(hexToBytes(args).length, 88);
  assert.equal(
    strip(args),
    strip(POOL_MANAGER) + strip(KEY.currency0) + strip(KEY.currency1) + "000bb8" + "00003c" + strip(KEY.hooks) + "00c8",
  );
});

test("test_F09_bandArgsNegativeTickSpacingIsTwosComplement", () => {
  // int24 packs to 3 bytes, two's complement, as abi.encodePacked does.
  const args = buildBandArgs(POOL_MANAGER, { ...KEY, tickSpacing: -60 }, 200);
  assert.equal(strip(args).slice(120 + 6, 120 + 12), "ffffc4");
});

test("test_F09_programLayout", () => {
  const args = buildBandArgs(POOL_MANAGER, KEY, 200);
  const program = buildBandProgram(FEE_0_30_PCT, BAND, args);
  // flatFee: opcode 21 (0x15), 4 bytes of args, fee 3_000_000 = 0x2dc6c0
  // xycSwap: opcode 17 (0x11), no args
  // extruction: opcode 32 (0x20), 108 args bytes (0x6c) = target (20) + band args (88)
  assert.equal(
    strip(program),
    "1504" + "002dc6c0" + "1100" + "206c" + strip(BAND) + strip(args),
  );
  assert.equal(hexToBytes(program).length, 6 + 2 + 2 + 108);
});

test("test_F09_orderEncodingExactBytes", () => {
  const args = buildBandArgs(POOL_MANAGER, KEY, 200);
  const program = buildBandProgram(FEE_0_30_PCT, BAND, args);
  // abi.encode(Order{maker, traits, data}), built here with viem and not with the SDK. With no hooks and no
  // receiver, data is the program itself; Aqua mode sets only bit 254 of traits (live: traits == 2^254).
  const expected = encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          { name: "maker", type: "address" },
          { name: "traits", type: "uint256" },
          { name: "data", type: "bytes" },
        ],
      },
    ],
    [{ maker: MAKER, traits: 1n << 254n, data: program }],
  );
  assert.equal(buildOrderEncoded(MAKER, program), expected);
});

import { assertSameBytes, firstByteDifference } from "../src/shipStrategy.js";

test("test_F09_firstByteDifference", () => {
  assert.equal(firstByteDifference("0x0102", "0x0102"), null);
  assert.equal(firstByteDifference("0x0102", "0x0103"), 1);
  assert.equal(firstByteDifference("0x01", "0x0102"), 1, "a prefix differs at the first missing byte");
  assert.equal(firstByteDifference("0xff0102", "0x0102"), 0);
});

test("test_F09_assertSameBytesNamesTheFirstDifference", () => {
  assertSameBytes("same", "0xabcd", "0xabcd");
  assert.throws(
    () => assertSameBytes("TS order vs orderHex", "0xaabbcc", "0xaabbdd"),
    /TS order vs orderHex: first difference at byte 2 \(got 0xcc, want 0xdd\); lengths 3 and 3/,
  );
});

// ---- step 5: the pure parts of demo.ts ----

import { encodeAbiParameters, encodeErrorResult, encodeEventTopics } from "viem";
import { confluenceHookAbi } from "../src/abis/ConfluenceHook.js";
import { poolPriceBandExtructionAbi } from "../src/abis/PoolPriceBandExtruction.js";
import { avgPrice, decodeSkipReason, formatTable, legsFromLogs, type RunRecord, type Snap } from "../src/demo.js";

test("test_F09_avgPrice", () => {
  const e18 = 10n ** 18n;
  // USDC in (6 decimals) per MUMB out (18 decimals), six decimals, rounded down.
  assert.equal(avgPrice(1000n * 10n ** 6n, 500n * e18, 6, 18), "2.000000");
  assert.equal(avgPrice(1000n * 10n ** 6n, 1000n * e18, 6, 18), "1.000000");
  assert.equal(avgPrice(1_000_000n, 3n * e18, 6, 18), "0.333333");
  assert.throws(() => avgPrice(1n, 0n, 6, 18), /zero/);
});

test("test_F09_decodeSkipReason", () => {
  const enc = (name: string, args?: readonly unknown[]) =>
    encodeErrorResult({ abi: [...confluenceHookAbi, ...poolPriceBandExtructionAbi], errorName: name, args } as never);

  assert.equal(
    decodeSkipReason(enc("PoolPriceBandExceeded", [1_031_000n, 1_000_000n, 200])),
    "PoolPriceBandExceeded(execX96=1031000, poolX96=1000000, bandBps=200): fill price 3.10% off the pool price, band 2.00%",
  );
  assert.equal(decodeSkipReason(enc("InsufficientGas", [123n])), "InsufficientGas(gasLeft=123)");
  assert.equal(decodeSkipReason(enc("PoolManagerShort", [4n])), "PoolManagerShort(available=4)");
  assert.equal(decodeSkipReason(enc("NoOrder")), "NoOrder()");
  assert.equal(decodeSkipReason("0x"), "empty reason (the router ran out of gas)");
  assert.equal(decodeSkipReason("0xdeadbeef0000"), "unknown error 0xdeadbeef (raw 0xdeadbeef0000)");
});

const HOOK: Address = "0x00000000000000000000000000000000000000d1";
const OTHER: Address = "0x00000000000000000000000000000000000000d2";
const POOL_ID: Hex = `0x${"11".repeat(32)}`;
const fakeLog = (address: Address, topics: readonly unknown[], data: Hex) =>
  ({ address, topics, data, blockNumber: 1n, transactionHash: `0x${"22".repeat(32)}`, logIndex: 0, removed: false }) as never;

test("test_F09_receiptLegs", () => {
  const maker: Address = "0x00000000000000000000000000000000000000f1";
  const fillTopics = encodeEventTopics({ abi: confluenceHookAbi, eventName: "AquaFill", args: { poolId: POOL_ID, maker } });
  const fillData = encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [550_000_000n, 545n]);
  const skipTopics = encodeEventTopics({ abi: confluenceHookAbi, eventName: "AquaSkipped", args: { poolId: POOL_ID } });
  const skipData = encodeAbiParameters([{ type: "bytes" }], ["0xabcd"]);

  const fill = legsFromLogs([fakeLog(HOOK, fillTopics, fillData)], HOOK);
  assert.deepEqual(fill, { fill: { amountIn: 550_000_000n, amountOut: 545n } });

  const skipped = legsFromLogs([fakeLog(HOOK, skipTopics, skipData)], HOOK);
  assert.deepEqual(skipped, { skipped: { reason: "0xabcd" } });

  // Events from another contract, and logs that are not the hook's, are ignored.
  assert.deepEqual(legsFromLogs([fakeLog(OTHER, fillTopics, fillData), fakeLog(HOOK, ["0x01"], "0x")], HOOK), {});
  // Two fills in one swap cannot happen; if the hook ever emitted two, say so loudly.
  assert.throws(
    () => legsFromLogs([fakeLog(HOOK, fillTopics, fillData), fakeLog(HOOK, fillTopics, fillData)], HOOK),
    /more than one AquaFill/,
  );
});

const e18 = 10n ** 18n;
const snap = (o: Partial<Snap> = {}): Snap => ({
  traderMumb: 0n,
  traderUsdc: 100_000n * 10n ** 6n,
  priyaMumb: 1_000_000n * e18,
  priyaUsdc: 1_000_000n * 10n ** 6n,
  aquaMumb: 100_000n * e18,
  aquaUsdc: 100_000n * 10n ** 6n,
  poolManagerMumb: 2_500n * e18,
  sqrtPrice: 1000n,
  liquidity: 123_456n,
  ...o,
});

test("test_F09_formatTable", () => {
  const usdc = 10n ** 6n;
  const poolOnly: RunRecord = {
    label: "pool only",
    hint: 0n,
    before: snap(),
    after: snap({
      traderMumb: 984_934_194_542_570_551_127n,
      traderUsdc: 99_000n * usdc,
      poolManagerMumb: 1_515n * e18,
      sqrtPrice: 1010n,
    }),
    usdcIn: 1000n * usdc,
    mumbOut: 984_934_194_542_570_551_127n,
    gasUsed: 150_000n,
  };
  const split: RunRecord = {
    label: "confluence",
    hint: 550n * usdc,
    before: snap(),
    after: snap({
      traderMumb: 991_549_823_315_669_231_761n,
      traderUsdc: 99_000n * usdc,
      priyaMumb: 1_000_000n * e18 - 545_359_521_066_233_309_646n,
      priyaUsdc: 1_000_000n * usdc + 550n * usdc,
      aquaMumb: 100_000n * e18 - 545_359_521_066_233_309_646n,
      aquaUsdc: 100_000n * usdc + 550n * usdc,
      poolManagerMumb: 2_500n * e18 - 446_190_302_249_435_922_115n,
      sqrtPrice: 1005n,
    }),
    usdcIn: 1000n * usdc,
    mumbOut: 991_549_823_315_669_231_761n,
    fill: { amountIn: 550n * usdc, amountOut: 545_359_521_066_233_309_646n },
    gasUsed: 331_781n,
  };
  const t = formatTable(poolOnly, split);
  assert.match(t, /MUMB out\s+984\.934194542570551127\s+991\.549823315669231761/);
  assert.match(t, /hint \(USDC to Aqua\)\s+0\s+550/);
  assert.match(t, /Aqua leg: MUMB out\s+0\s+545\.359521066233309646/);
  assert.match(t, /pool leg: MUMB out\s+984\.934194542570551127\s+446\.190302249435922115/);
  assert.match(t, /Priya wallet MUMB, after\s+1000000\s+999454\.640478933766690354/);
  assert.match(t, /Priya Aqua USDC, after\s+100000\s+100550/);
  // The price is sqrtPrice squared: 1000^2 -> 1010^2 is a 2.01% move, 1000^2 -> 1005^2 is 1.00%.
  assert.match(t, /pool price move \(slot0\)\s+2\.01%\s+1\.00%/);
  assert.doesNotMatch(t, /liquidity/, "liquidity stays in last-demo.json only");
  assert.match(t, /gain vs pool only: \+6\.615628773098680634 MUMB \(\+67\.16 bps\)/);
  // The table is a pure function of its inputs: same records, same text.
  assert.equal(formatTable(poolOnly, split), t);
});

import { guardChecks } from "../src/demo.js";

test("test_F09_guardChecks", () => {
  const usdc = 10n ** 6n;
  const bandReason = encodeErrorResult({
    abi: poolPriceBandExtructionAbi,
    errorName: "PoolPriceBandExceeded",
    args: [1_031_000n, 1_000_000n, 200],
  });
  const good: RunRecord = {
    label: "hinted swap",
    hint: 550n * usdc,
    before: snap(),
    after: snap({ traderMumb: 949n * e18, traderUsdc: 99_000n * usdc }),
    usdcIn: 1000n * usdc,
    mumbOut: 949n * e18,
    skipped: bandReason,
    gasUsed: 235_572n,
  };
  const failures = (r: RunRecord) => guardChecks(r, 1000n * usdc).filter(([ok]) => !ok).map(([, what]) => what);

  assert.deepEqual(failures(good), [], "the good case passes every check");
  // No AquaSkipped at all: the swap went another way.
  assert.match(failures({ ...good, skipped: undefined }).join("|"), /AquaSkipped was emitted/);
  // Priya was filled.
  assert.match(
    failures({ ...good, skipped: undefined, fill: { amountIn: 1n, amountOut: 1n } }).join("|"),
    /no AquaFill/,
  );
  // Skipped, but for another reason than the band: not the guard we are showing.
  const other = encodeErrorResult({ abi: confluenceHookAbi, errorName: "NoOrder" });
  assert.match(failures({ ...good, skipped: other }).join("|"), /PoolPriceBandExceeded/);
  // The trader got nothing, or Priya's balances moved.
  assert.match(failures({ ...good, mumbOut: 0n }).join("|"), /received MUMB/);
  assert.match(failures({ ...good, after: snap({ priyaMumb: 1n }) }).join("|"), /untouched/);
});
