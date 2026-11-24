import { createPublicClient, createWalletClient, defineChain, http, type Hex, parseGwei } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { loadDeployment } from "@ticktock/shared";
import { createKeeper, defaultLog } from "./keeper.js";

/**
 * Runs the keeper until stopped. Settings, from the environment (the repository's .env is loaded):
 *   TICKTOCK_DEPLOYMENT          the deployment file (default: deployments/unichain-sepolia.json)
 *   KEEPER_RPC_URL               default: the public Unichain Sepolia endpoint
 *   KEEPER_PRIVATE_KEY           the keeper's key; falls back to PRIVATE_KEY (the testnet key)
 *   KEEPER_POLL_MS               time between runs (default 2000)
 *   KEEPER_MAX_OPS               the budget of each flipCrossed (default: the factory's maxOpsPerSwap)
 *   KEEPER_MAX_GAS_PRICE_GWEI    nothing is sent above this (default 1)
 *   KEEPER_START_BLOCK           where to start reading logs (default: the deployment's start block)
 *   KEEPER_DRY_RUN=1             simulate only
 */
const deployment = loadDeployment();
const rpc = process.env.KEEPER_RPC_URL ?? "https://sepolia.unichain.org";
const privateKey = (process.env.KEEPER_PRIVATE_KEY ?? process.env.PRIVATE_KEY) as Hex | undefined;
if (!privateKey) throw new Error("set KEEPER_PRIVATE_KEY or PRIVATE_KEY");

const chain = defineChain({
  id: deployment.chainId,
  name: `chain ${deployment.chainId}`,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [rpc] } },
});
const transport = http(rpc);
const account = privateKeyToAccount(privateKey);
const pollMs = Number(process.env.KEEPER_POLL_MS ?? 2_000);

const keeper = createKeeper({
  publicClient: createPublicClient({ chain, transport }),
  walletClient: createWalletClient({ chain, transport, account }),
  factory: deployment.factory,
  poolManager: deployment.poolManager,
  stateView: deployment.stateView,
  startBlock: BigInt(process.env.KEEPER_START_BLOCK ?? deployment.startBlock),
  maxOps: BigInt(process.env.KEEPER_MAX_OPS ?? deployment.maxOpsPerSwap),
  maxGasPriceWei: parseGwei(process.env.KEEPER_MAX_GAS_PRICE_GWEI ?? "1"),
  dryRun: process.env.KEEPER_DRY_RUN === "1",
});

let stopping = false;
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    stopping = true;
  });
}

defaultLog({ msg: "keeper started", account: account.address, chainId: deployment.chainId, hook: deployment.hook });
while (!stopping) {
  try {
    await keeper.runOnce();
  } catch (error) {
    defaultLog({ msg: "run failed", error: String(error) });
  }
  await new Promise((r) => setTimeout(r, pollMs));
}
defaultLog({ msg: "keeper stopped", ...keeper.state() });
