// Shared script config. Addresses come from deployments/local.json (written by the
// setup script) and the RPC URL from the environment; nothing is inlined here.
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { Address, Hex } from "viem";

/**
 * Gas limit for every swap transaction and every simulation of one (ARCHITECTURE
 * section 7, D-20). The hook skips Aqua below a limit of about 396,525 and a fill needs
 * about 458,300, so a simulation at any other limit can show a different split from the
 * transaction. The demo runner (F09) and the web app (F10) must use this same value.
 */
export const SWAP_GAS_LIMIT = 1_500_000n;

export const USDC_DECIMALS = 6;
export const MUMB_DECIMALS = 18;

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

export interface PoolKeyJson {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

export interface Deployment {
  usdc: Address;
  mumb: Address;
  hook: Address;
  /** The swap router the trader uses (v4-core PoolSwapTest in the local demo). */
  swapRouter: Address;
  poolKey: PoolKeyJson;
  /** PoolPriceBandExtruction, the Extruction target in Priya's program. */
  band: Address;
  /** The Aqua registry. */
  aqua: Address;
  /** The canonical AquaSwapVMRouter v1.0.2: the Aqua `app` Priya ships to. */
  swapVmRouter: Address;
  poolManager: Address;
  /** abi.encode(Order) of the order Setup registered in the hook; shipStrategy.ts must rebuild exactly these bytes. */
  orderHex: Hex;
  /** keccak256(orderHex): the Aqua strategy hash the ship must produce. */
  expectedStrategyHash: Hex;
  /** Band width in basis points, as in the registered order's Extruction args. */
  bandBps: number;
  /** Priya's flat fee on the 1e9 scale (3000000 = 0.30%). */
  feeE9: number;
  /** Priya, the maker. */
  maker: Address;
  /** The trader the quoter simulates as. */
  trader: Address;
  /** anvil snapshot id taken after setup (F09). */
  snapshotId?: string;
}

export const DEPLOYMENT_PATH = resolve(root, "deployments/local.json");

export function loadDeployment(path: string = DEPLOYMENT_PATH): Deployment {
  if (!existsSync(path)) {
    throw new Error(`${path} not found: run the setup script first (F09)`);
  }
  return JSON.parse(readFileSync(path, "utf8")) as Deployment;
}

/** The local anvil node. Not a secret, so it has a default. */
export function rpcUrl(): string {
  return process.env.ANVIL_RPC_URL ?? "http://127.0.0.1:8545";
}
