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

test("test_F09_orderEncodingShape", () => {
  const args = buildBandArgs(POOL_MANAGER, KEY, 200);
  const program = buildBandProgram(FEE_0_30_PCT, BAND, args);
  const order = buildOrderEncoded(MAKER, program);
  // abi.encode(Order{maker, traits, data}); with no hooks, data is the program itself. Byte equality with
  // the order StrategyLib built is checked live (test_F09_live_tsOrderEqualsRegisteredOrder).
  assert.ok(strip(order).includes(strip(program)), "the program is the order's data");
  assert.ok(strip(order).includes(strip(MAKER)), "the maker is in the order");
  assert.equal(keccak256(order).length, 66);
});
