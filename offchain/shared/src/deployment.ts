import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { Address, Hex } from "viem";

/** The file `script/testnet/DeployTestnet.s.sol` writes. */
export type Deployment = {
  chainId: number;
  /** The block the deployment started at: indexing starts here. */
  startBlock: number;
  poolManager: Address;
  universalRouter: Address;
  quoter: Address;
  stateView: Address;
  permit2: Address;
  factory: Address;
  implementation: Address;
  engine: Address;
  hook: Address;
  maxOpsPerSwap: number;
  levelSpacing: number;
  spreads: number[];
  /** The starting price, in whole quote tokens per base token. */
  price: number;
  tokens: { base: Address; quote: Address };
  pool: PoolKey & { id: Hex };
};

export type PoolKey = {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
};

/** The repository's deployments folder, from anywhere under offchain/. */
export const deploymentsDir = resolve(dirname(fileURLToPath(import.meta.url)), "../../../deployments");

/** Reads a deployment file: TICKTOCK_DEPLOYMENT if set, else Unichain Sepolia's. */
export function loadDeployment(path = process.env.TICKTOCK_DEPLOYMENT): Deployment {
  const file = path ?? resolve(deploymentsDir, "unichain-sepolia.json");
  return JSON.parse(readFileSync(file, "utf8")) as Deployment;
}

export function poolKeyOf(d: Deployment): PoolKey {
  const { currency0, currency1, fee, tickSpacing, hooks } = d.pool;
  return { currency0, currency1, fee, tickSpacing, hooks };
}
