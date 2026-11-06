// F09: Priya's program and order, built with the 1inch SDK (typescript.md: AquaProgramBuilder, and the
// result must encode to the same bytes as contracts/test/base/StrategyLib.sol for the same parameters).
import { Address, AquaProgramBuilder, HexString, MakerTraits, Order, instructions } from "@1inch/swap-vm-sdk";
import { encodePacked, type Address as Addr, type Hex } from "viem";
import type { PoolKeyJson } from "./config.js";

const { ExtructionArgs, extruction } = instructions.extruction;

/** SwapVM's fee scale is 1e9 = 100%, so this is 0.30% (StrategyLib.FEE_0_30_PCT). */
export const FEE_0_30_PCT = 3_000_000n;

/**
 * The 88 bytes PoolPriceBandExtruction reads from the strategy:
 * poolManager | currency0 | currency1 | fee (3) | tickSpacing (3) | hooks | bandBps (2).
 * Same packing as `PoolPriceBandExtruction.build` (checked live against the contract).
 */
export function buildBandArgs(poolManager: Addr, key: PoolKeyJson, bandBps: number): Hex {
  if (!Number.isInteger(bandBps) || bandBps <= 0 || bandBps > 10_000) throw new Error(`invalid bandBps ${bandBps}`);
  return encodePacked(
    ["address", "address", "address", "uint24", "int24", "address", "uint16"],
    [poolManager, key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks, bandBps],
  );
}

/**
 * Flat input fee, the XYC curve, then the band check (StrategyLib._buildBandProgram). The Extruction step
 * is added through `add` because `AquaProgramBuilder` has no `.extruction()` method; the opcode is in its
 * set, and `add` rejects any opcode the canonical router does not have.
 */
export function buildBandProgram(feeE9: bigint, target: Addr, bandArgs: Hex): Hex {
  const program = new AquaProgramBuilder()
    .flatFeeAmountInXD({ fee: feeE9 })
    .xycSwapXD()
    .add(extruction.createIx(new ExtructionArgs(new Address(target), new HexString(bandArgs))))
    .build();
  return program.toString() as Hex;
}

/** An Aqua-mode order with no hooks and no receiver (StrategyLib._buildOrder), ABI-encoded as the router takes it. */
export function buildOrderEncoded(maker: Addr, program: Hex): Hex {
  const order = Order.new({
    maker: new Address(maker),
    traits: MakerTraits.default(),
    program: new HexString(program),
  });
  return order.encode().toString() as Hex;
}
