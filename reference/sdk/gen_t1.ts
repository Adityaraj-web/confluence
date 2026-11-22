// V2-05: golden vectors for template T1, produced by the 1inch SDK (@1inch/swap-vm-sdk 0.4.0), never by our
// Solidity. The guard args are packed with viem, as the SDK has no BandGuardV2 type.
// Run from the repo root:  scripts/node_modules/.bin/tsx reference/sdk/gen_t1.ts
// Output: contracts/test/sdk-vectors/t1_sdk.json (kept out of contracts/test/vectors, which V200 asserts holds exactly
// the five files reference/gen_vectors.py writes; sorted keys, no timestamps: byte-identical on rerun).
import { writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Address, AquaProgramBuilder, HexString, MakerTraits, Order, instructions } from "../../scripts/node_modules/@1inch/swap-vm-sdk/dist/index.mjs";
import { encodePacked, keccak256, type Address as Addr, type Hex } from "../../scripts/node_modules/viem/_esm/index.js";

const { ExtructionArgs, extruction } = instructions.extruction;

const MAKER: Addr = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const POOL_MANAGER: Addr = "0x000000000004444c5dc75cB358380D2e3dE08A90";
const CURRENCY0: Addr = "0x1111111111111111111111111111111111111111";
const CURRENCY1: Addr = "0x2222222222222222222222222222222222222222";
const HOOKS: Addr = "0x3333333333333333333333333333333333333333";
const GUARD: Addr = "0x4444444444444444444444444444444444444444";

interface Case {
  name: string;
  feeE9: bigint;
  bandBps: number;
  driftTicks: number;
  exclusive: boolean;
  salt: bigint; // 0 = no salt step
  fee: number; // pool fee
  tickSpacing: number;
}

const cases: Case[] = [
  { name: "A_noSalt_030_exclusive", feeE9: 3_000_000n, bandBps: 200, driftTicks: 300, exclusive: true, salt: 0n, fee: 3000, tickSpacing: 60 },
  { name: "B_salt1_zeroFee_open", feeE9: 0n, bandBps: 1, driftTicks: 0, exclusive: false, salt: 1n, fee: 500, tickSpacing: 10 },
  { name: "C_saltMax_maxFee_edges", feeE9: 999_999_999n, bandBps: 10_000, driftTicks: 10_000, exclusive: true, salt: 2n ** 64n - 1n, fee: 10_000, tickSpacing: 200 },
];

function build(c: Case) {
  const args: Hex = encodePacked(
    ["address", "address", "address", "uint24", "int24", "address", "uint16", "uint16", "uint8"],
    [POOL_MANAGER, CURRENCY0, CURRENCY1, c.fee, c.tickSpacing, HOOKS, c.bandBps, c.driftTicks, c.exclusive ? 1 : 0],
  );
  let b = new AquaProgramBuilder();
  if (c.salt !== 0n) b = b.salt({ salt: c.salt });
  const program = b
    .flatFeeAmountInXD({ fee: c.feeE9 })
    .xycSwapXD()
    .add(extruction.createIx(new ExtructionArgs(new Address(GUARD), new HexString(args))))
    .build()
    .toString() as Hex;
  const order = Order.new({
    maker: new Address(MAKER),
    traits: MakerTraits.default(),
    program: new HexString(program),
  })
    .encode()
    .toString() as Hex;
  return { args, program, order, hash: keccak256(order) };
}

const out = {
  schema: 1,
  file: "t1_sdk.json",
  description: "Template T1 programs and Aqua orders built by @1inch/swap-vm-sdk 0.4.0 (reference/sdk/gen_t1.ts)",
  maker: MAKER,
  poolManager: POOL_MANAGER,
  currency0: CURRENCY0,
  currency1: CURRENCY1,
  hooks: HOOKS,
  guard: GUARD,
  cases: cases.map((c) => {
    const r = build(c);
    return {
      name: c.name,
      feeE9: c.feeE9.toString(),
      bandBps: c.bandBps,
      driftTicks: c.driftTicks,
      exclusive: c.exclusive,
      salt: c.salt.toString(),
      fee: c.fee,
      tickSpacing: c.tickSpacing,
      args: r.args,
      program: r.program,
      order: r.order,
      hash: r.hash,
    };
  }),
};

const sort = (v: unknown): unknown =>
  Array.isArray(v) ? v.map(sort) : v && typeof v === "object" ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sort((v as Record<string, unknown>)[k])])) : v;

const here = dirname(fileURLToPath(import.meta.url));
writeFileSync(resolve(here, "../../contracts/test/sdk-vectors/t1_sdk.json"), JSON.stringify(sort(out), null, 2) + "\n");
console.log("wrote t1_sdk.json");
