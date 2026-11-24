import { createConfig, factory } from "ponder";
import { getAbiItem } from "viem";
import { loadDeployment, poolManagerAbi, tickTockFactoryAbi, tickTockHookAbi } from "@ticktock/shared";

/**
 * Indexes one deployment: the factory's hooks, everything their pools do, and the swaps on the deployment's pools.
 * TICKTOCK_DEPLOYMENT picks the deployment file (default: Unichain Sepolia's), PONDER_RPC_URL the endpoint.
 */
const deployment = loadDeployment();
const rpc = process.env.PONDER_RPC_URL ?? "https://sepolia.unichain.org";
const local = /127\.0\.0\.1|localhost/.test(rpc);

export default createConfig({
  database: process.env.DATABASE_URL
    ? { kind: "postgres", connectionString: process.env.DATABASE_URL }
    : { kind: "pglite", directory: process.env.PONDER_PGLITE_DIRECTORY },
  chains: {
    // A local chain resets between runs, so its responses must not be cached.
    unichain: { id: deployment.chainId, rpc, cacheRpcRequests: !local, pollingInterval: local ? 250 : 1_000 },
  },
  contracts: {
    TickTockFactory: {
      chain: "unichain",
      abi: tickTockFactoryAbi,
      address: deployment.factory,
      startBlock: deployment.startBlock,
    },
    TickTockHook: {
      chain: "unichain",
      abi: tickTockHookAbi,
      address: factory({
        address: deployment.factory,
        event: getAbiItem({ abi: tickTockFactoryAbi, name: "HookCreated" }),
        parameter: "hook",
      }),
      startBlock: deployment.startBlock,
    },
    // Swaps are emitted by the PoolManager for every pool on the chain, so only the deployment's pools are indexed.
    PoolManager: {
      chain: "unichain",
      abi: poolManagerAbi,
      address: deployment.poolManager,
      startBlock: deployment.startBlock,
      filter: { event: "Swap", args: { id: [deployment.pool.id] } },
    },
  },
});
