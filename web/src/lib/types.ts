// F10 data contract (spec "Data source interface"). Browser-safe: no node: imports, no enums.
// Bigints travel as decimal strings in JSON (…Json types); the engine converts at the edges.

export type Hex = `0x${string}`;
export type Address = `0x${string}`;

export type Direction = "usdc-to-mumb" | "mumb-to-usdc";

/** What readSnap returns (copy of scripts/src/demo.ts Snap). */
export interface Snap {
  traderMumb: bigint;
  traderUsdc: bigint;
  priyaMumb: bigint;
  priyaUsdc: bigint;
  aquaMumb: bigint;
  aquaUsdc: bigint;
  poolManagerMumb: bigint;
  sqrtPrice: bigint;
  liquidity: bigint;
}
export type SnapJson = { [K in keyof Snap]: string };

/** Copy of scripts/src/demo.ts RunRecord. */
export interface RunRecord {
  label: string;
  hint: bigint;
  before: Snap;
  after: Snap;
  usdcIn: bigint;
  mumbOut: bigint;
  fill?: { amountIn: bigint; amountOut: bigint };
  skipped?: Hex;
  gasUsed: bigint;
}

/** RunRecord with bigints as decimal strings, plus the decoded skip reason. No label: the file position says which run it is. */
export interface RunJson {
  hint: string;
  before: SnapJson;
  after: SnapJson;
  usdcIn: string;
  mumbOut: string;
  fill?: { amountIn: string; amountOut: string };
  /** Raw AquaSkipped reason bytes. */
  skipped?: Hex;
  /** decodeSkipReason(skipped), words. */
  skipReason?: string;
  gasUsed: string;
}

export interface QuotePoint {
  hint: string;
  /** null = the simulation reverted. */
  out: string | null;
}

export interface RunFile {
  schema: 1;
  fork: { block: number };
  request: { dir: Direction; amountIn: string };
  quote: { points: QuotePoint[]; hint: string; aquaShare: number };
  poolOnly: RunJson;
  split: RunJson;
}

export interface GuardFile {
  schema: 1;
  fork: { block: number };
  amountIn: string;
  hint: string;
  move: { amountIn: string; out: string; sqrtBefore: string; sqrtAfter: string };
  hinted: RunJson & { skipReason: string };
}

/** Pool facts the header and Depth chips need (gap 1: they are not in the run files). */
export interface PoolMeta {
  fee: number;
  tickSpacing: number;
  bandBps: number;
  feeE9: number;
  usdcIsCurrency0: boolean;
}

export interface Header {
  pool: PoolMeta;
  forkBlock: number;
  sqrtPrice: string;
  /** USDC per 1 MUMB, six decimals, rounded down: "1.000000". */
  usdcPerMumb: string;
  liquidity: string;
}

/** web/public/runs/index.json (gap 1). No timestamps, hashes or snapshot ids. */
export interface RunsIndex {
  schema: 1;
  fork: { block: number };
  pool: PoolMeta;
  addresses: {
    usdc: Address;
    mumb: Address;
    hook: Address;
    band: Address;
    poolManager: Address;
    aqua: Address;
    swapVmRouter: Address;
  };
  runs: { file: string; dir: Direction; amount: string }[];
  guard: { file: string; amount: string };
}

export interface DataSource {
  kind: "live" | "replay";
  header(): Promise<Header>;
  /** Human decimal amounts ("500", "1000"); replay: recorded only, live: "any" (gap 6). */
  amounts(dir: Direction): string[] | "any";
  compare(req: { dir: Direction; amountIn: bigint }, onPoint?: (p: QuotePoint) => void): Promise<RunFile>;
  guard(amountIn: bigint): Promise<GuardFile>;
}

/** The subset of deployments/local.json the browser needs (copy of scripts/src/config.ts Deployment). */
export interface PoolKeyJson {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

export interface DeploymentJson {
  usdc: Address;
  mumb: Address;
  hook: Address;
  swapRouter: Address;
  poolKey: PoolKeyJson;
  band: Address;
  aqua: Address;
  swapVmRouter: Address;
  poolManager: Address;
  expectedStrategyHash: Hex;
  bandBps: number;
  feeE9: number;
  maker: Address;
  trader: Address;
  snapshotId?: string;
}
