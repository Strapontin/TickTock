/**
 * A local chain for the off-chain tests: anvil forking Unichain Sepolia at a pinned block, with TickTock deployed and
 * seeded by the repository's own Foundry scripts. Needs `anvil` and `forge` (Foundry) and network access to the
 * Sepolia RPC the first time; anvil caches the forked state after that.
 */
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  type Address,
  createPublicClient,
  createWalletClient,
  encodeAbiParameters,
  encodePacked,
  type Hex,
  http,
  maxUint160,
  maxUint256,
  maxUint48,
  type PublicClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { testTokenAbi, tickTockHookAbi } from "../src/abis.js";
import { type Deployment, loadDeployment } from "../src/deployment.js";

export const repoRoot = resolve(fileURLToPath(new URL(".", import.meta.url)), "../../..");

/** Anvil's first default account: funded on every anvil chain, and public. Never use it anywhere else. */
export const ANVIL_KEY: Hex = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
export const anvilAccount = privateKeyToAccount(ANVIL_KEY);
/** Anvil's second default account, for the keeper. Public too. */
export const ANVIL_KEEPER_KEY: Hex = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";

/** v4's PoolSwapTest on Unichain Sepolia: swaps to an exact price limit, which the Universal Router can't. */
const POOL_SWAP_TEST: Address = "0x9140a78c1a137c7ff1c151ec8231272af78a99a4";

const SEPOLIA_RPC = process.env.UNICHAIN_SEPOLIA_RPC_URL ?? "https://sepolia.unichain.org";
const FORK_BLOCK = 68_690_000;
const env = { ...process.env, PATH: `${join(homedir(), ".foundry/bin")}:${process.env.PATH}` };

export type LocalChain = {
  rpc: string;
  publicClient: PublicClient;
  deployment: Deployment;
  deploymentPath: string;
  stop: () => Promise<void>;
};

/** Starts anvil on `port`, then deploys and seeds TickTock into `deployments/<name>.json`. */
export async function startLocalChain(name: string, port: number): Promise<LocalChain> {
  const rpc = `http://127.0.0.1:${port}`;
  const anvil = spawn(
    "anvil",
    ["--fork-url", SEPOLIA_RPC, "--fork-block-number", String(FORK_BLOCK), "--port", String(port), "--silent"],
    { env, stdio: "ignore" },
  );
  // No caching: the tests compare against the chain right after each transaction.
  const publicClient = createPublicClient({ transport: http(rpc), cacheTime: 0 });
  await waitFor(async () => (await publicClient.getChainId()) > 0, 30_000, "anvil");

  const deploymentPath = join(repoRoot, "deployments", `${name}.json`);
  const broadcastDir = mkdtempSync(join(tmpdir(), "ticktock-broadcast-"));
  const scriptEnv = { DEPLOYMENT: deploymentPath, PRIVATE_KEY: ANVIL_KEY, FOUNDRY_BROADCAST: broadcastDir };
  forgeScript("script/testnet/DeployTestnet.s.sol", rpc, scriptEnv);
  forgeScript("script/testnet/Seed.s.sol", rpc, scriptEnv);

  return {
    rpc,
    publicClient,
    deployment: loadDeployment(deploymentPath),
    deploymentPath,
    stop: async () => {
      await stopProcess(anvil);
      rmSync(deploymentPath, { force: true });
      rmSync(broadcastDir, { recursive: true, force: true });
    },
  };
}

function forgeScript(script: string, rpc: string, extraEnv: Record<string, string>) {
  const result = spawnSync("forge", ["script", script, "--rpc-url", rpc, "--broadcast", "--slow"], {
    cwd: repoRoot,
    env: { ...env, ...extraEnv },
    encoding: "utf8",
  });
  if (result.status !== 0) throw new Error(`forge script ${script} failed:\n${result.stdout}\n${result.stderr}`);
}

/** One swap through the Universal Router, from anvil's account: mints the input, approves Permit2, swaps. */
export async function trade(chain: LocalChain, zeroForOne: boolean, amountIn: bigint) {
  const { deployment: d, publicClient } = chain;
  const wallet = createWalletClient({ account: anvilAccount, transport: http(chain.rpc) });
  const input = zeroForOne ? d.pool.currency0 : d.pool.currency1;
  const send = async (hash: Promise<Hex>) => publicClient.waitForTransactionReceipt({ hash: await hash });

  await send(wallet.writeContract({ chain: null, abi: testTokenAbi, address: input, functionName: "mint", args: [anvilAccount.address, amountIn] }));
  await send(wallet.writeContract({ chain: null, abi: testTokenAbi, address: input, functionName: "approve", args: [d.permit2, maxUint256] }));
  await send(
    wallet.writeContract({
      chain: null,
      abi: permit2Abi,
      address: d.permit2,
      functionName: "approve",
      args: [input, d.universalRouter, maxUint160, Number(maxUint48)],
    }),
  );
  const { commands, inputs } = exactInputSingle(d, zeroForOne, amountIn);
  const receipt = await send(
    wallet.writeContract({
      chain: null,
      abi: universalRouterAbi,
      address: d.universalRouter,
      functionName: "execute",
      args: [commands, inputs, BigInt(Math.floor(Date.now() / 1000) + 3600)],
    }),
  );
  if (receipt.status !== "success") throw new Error("trade reverted");
  return receipt;
}

/** A deposit from anvil's account, minting and approving what it pays with. */
export async function deposit(
  chain: LocalChain,
  sellLevel: number,
  spreadIndex: number,
  startWithToken0: boolean,
  amount: bigint,
) {
  const d = chain.deployment;
  const wallet = createWalletClient({ account: anvilAccount, transport: http(chain.rpc) });
  const token = startWithToken0 ? d.pool.currency0 : d.pool.currency1;
  const send = async (hash: Promise<Hex>) => chain.publicClient.waitForTransactionReceipt({ hash: await hash });
  await send(wallet.writeContract({ chain: null, abi: testTokenAbi, address: token, functionName: "mint", args: [anvilAccount.address, amount] }));
  await send(wallet.writeContract({ chain: null, abi: testTokenAbi, address: token, functionName: "approve", args: [d.hook, maxUint256] }));
  const receipt = await send(
    wallet.writeContract({
      chain: null,
      abi: tickTockHookAbi,
      address: d.hook,
      functionName: "deposit",
      args: [poolKey(d), sellLevel, spreadIndex, startWithToken0, amount, 0n, anvilAccount.address, 2n ** 40n],
    }),
  );
  if (receipt.status !== "success") throw new Error("deposit reverted");
  return receipt;
}

/** Swaps from anvil's account until the price reaches `sqrtPriceX96`, through v4's PoolSwapTest. */
export async function swapTo(chain: LocalChain, sqrtPriceX96: bigint) {
  const d = chain.deployment;
  const wallet = createWalletClient({ account: anvilAccount, transport: http(chain.rpc) });
  const send = async (hash: Promise<Hex>) => chain.publicClient.waitForTransactionReceipt({ hash: await hash });
  const { sqrtPriceX96: current } = await slot0(chain);
  const zeroForOne = sqrtPriceX96 < current;
  const input = zeroForOne ? d.pool.currency0 : d.pool.currency1;
  const funds = 10n ** 40n;
  await send(wallet.writeContract({ chain: null, abi: testTokenAbi, address: input, functionName: "mint", args: [anvilAccount.address, funds] }));
  await send(wallet.writeContract({ chain: null, abi: testTokenAbi, address: input, functionName: "approve", args: [POOL_SWAP_TEST, maxUint256] }));
  const receipt = await send(
    wallet.writeContract({
      chain: null,
      abi: poolSwapTestAbi,
      address: POOL_SWAP_TEST,
      functionName: "swap",
      args: [
        poolKey(d),
        { zeroForOne, amountSpecified: -(2n ** 120n), sqrtPriceLimitX96: sqrtPriceX96 },
        { takeClaims: false, settleUsingBurn: false },
        "0x",
      ],
    }),
  );
  if (receipt.status !== "success") throw new Error("swap reverted");
  return receipt;
}

export async function slot0(chain: LocalChain): Promise<{ sqrtPriceX96: bigint; tick: number }> {
  const [sqrtPriceX96, tick] = await chain.publicClient.readContract({
    abi: stateViewAbi,
    address: chain.deployment.stateView,
    functionName: "getSlot0",
    args: [chain.deployment.pool.id],
  });
  return { sqrtPriceX96, tick };
}

function poolKey(d: Deployment) {
  const { currency0, currency1, fee, tickSpacing, hooks } = d.pool;
  return { currency0, currency1, fee, tickSpacing, hooks };
}

const stateViewAbi = [
  {
    type: "function",
    name: "getSlot0",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [
      { name: "sqrtPriceX96", type: "uint160" },
      { name: "tick", type: "int24" },
      { name: "protocolFee", type: "uint24" },
      { name: "lpFee", type: "uint24" },
    ],
  },
] as const;

const poolSwapTestAbi = [
  {
    type: "function",
    name: "swap",
    stateMutability: "payable",
    inputs: [
      {
        name: "key",
        type: "tuple",
        components: [
          { name: "currency0", type: "address" },
          { name: "currency1", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "tickSpacing", type: "int24" },
          { name: "hooks", type: "address" },
        ],
      },
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "zeroForOne", type: "bool" },
          { name: "amountSpecified", type: "int256" },
          { name: "sqrtPriceLimitX96", type: "uint160" },
        ],
      },
      {
        name: "testSettings",
        type: "tuple",
        components: [
          { name: "takeClaims", type: "bool" },
          { name: "settleUsingBurn", type: "bool" },
        ],
      },
      { name: "hookData", type: "bytes" },
    ],
    outputs: [{ name: "delta", type: "int256" }],
  },
] as const;

// The Universal Router encoding, as in script/UniversalRouterSwap.sol.

const permit2Abi = [
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "spender", type: "address" },
      { name: "amount", type: "uint160" },
      { name: "expiration", type: "uint48" },
    ],
    outputs: [],
  },
] as const;

const universalRouterAbi = [
  {
    type: "function",
    name: "execute",
    stateMutability: "payable",
    inputs: [
      { name: "commands", type: "bytes" },
      { name: "inputs", type: "bytes[]" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [],
  },
] as const;

const poolKeyType = {
  type: "tuple",
  components: [
    { name: "currency0", type: "address" },
    { name: "currency1", type: "address" },
    { name: "fee", type: "uint24" },
    { name: "tickSpacing", type: "int24" },
    { name: "hooks", type: "address" },
  ],
} as const;

function exactInputSingle(d: Deployment, zeroForOne: boolean, amountIn: bigint) {
  const key = {
    currency0: d.pool.currency0,
    currency1: d.pool.currency1,
    fee: d.pool.fee,
    tickSpacing: d.pool.tickSpacing,
    hooks: d.pool.hooks,
  };
  const [input, output]: [Address, Address] = zeroForOne
    ? [d.pool.currency0, d.pool.currency1]
    : [d.pool.currency1, d.pool.currency0];
  const swapParams = encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          { name: "poolKey", ...poolKeyType },
          { name: "zeroForOne", type: "bool" },
          { name: "amountIn", type: "uint128" },
          { name: "amountOutMinimum", type: "uint128" },
          { name: "hookData", type: "bytes" },
        ],
      },
    ],
    [{ poolKey: key, zeroForOne, amountIn, amountOutMinimum: 0n, hookData: "0x" }],
  );
  const settle = encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [input, amountIn]);
  const take = encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [output, 0n]);
  // SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL; then the V4_SWAP command.
  const actions = encodePacked(["uint8", "uint8", "uint8"], [0x06, 0x0c, 0x0f]);
  const v4Input = encodeAbiParameters([{ type: "bytes" }, { type: "bytes[]" }], [actions, [swapParams, settle, take]]);
  return { commands: encodePacked(["uint8"], [0x10]), inputs: [v4Input] };
}

// ---------------------------------------------------------------------------------------------------------------
// Processes
// ---------------------------------------------------------------------------------------------------------------

export async function waitFor(check: () => Promise<boolean>, timeoutMs: number, what: string) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      if (await check()) return;
    } catch {
      // not up yet
    }
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 250));
  }
}

export async function stopProcess(child: ChildProcess) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = new Promise((r) => child.once("exit", r));
  child.kill("SIGTERM");
  const timer = setTimeout(() => child.kill("SIGKILL"), 5_000);
  await exited;
  clearTimeout(timer);
}
