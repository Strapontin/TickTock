import {
  type Account,
  type Address,
  BaseError,
  type Chain,
  ContractFunctionRevertedError,
  getAbiItem,
  type Hex,
  parseEventLogs,
  type PublicClient,
  type Transport,
  type WalletClient,
} from "viem";
import { type PoolKey, tickTockFactoryAbi, tickTockHookAbi, poolManagerAbi } from "@ticktock/shared";

/**
 * The keeper bot (DESIGN.md section 5.3, README "Keepers"). Each run:
 * 1. Reads the logs since the last run: new hooks, new pools, activity on known pools, and `LevelSkipped`.
 * 2. For each pool with activity, calls `flipCrossed` until nothing crossed is left, then `flipLevel` on the level the
 *    price is inside, which flips it once 90% is sold.
 * 3. Calls `flipLevel` on every level a scan skipped, until it flips or isn't crossed any more.
 * It only sends what its simulation says will succeed and do work, and nothing above its gas price cap.
 */

export type KeeperOptions = {
  publicClient: PublicClient;
  walletClient: WalletClient<Transport, Chain, Account>;
  factory: Address;
  poolManager: Address;
  stateView: Address;
  /** The block to start reading logs from: the deployment's. */
  startBlock: bigint;
  /** The operations budget for each `flipCrossed`. At least 9, so the busiest level fits. */
  maxOps?: bigint;
  /** No transaction is sent while the gas price is above this. */
  maxGasPriceWei?: bigint;
  /** The block range of each `eth_getLogs` call. */
  logChunk?: bigint;
  /** Simulate only, never send. */
  dryRun?: boolean;
  log?: (entry: Record<string, unknown>) => void;
};

export type Action = {
  kind: "flipCrossed" | "flipLevel";
  poolId: Hex;
  level?: number;
  /** `flipCrossed`'s simulated operations. */
  ops?: bigint;
  status: "sent" | "dry-run" | "gas-price-too-high" | "reverted";
  hash?: Hex;
  gasUsed?: bigint;
};

type Pool = { id: Hex; key: PoolKey; levelSpacing: number };

const MAX_FLIP_CROSSED_PER_RUN = 20;

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

/** One JSON object per line, with a timestamp. */
export function defaultLog(entry: Record<string, unknown>) {
  const line = { time: new Date().toISOString(), ...entry };
  console.log(JSON.stringify(line, (_, v) => (typeof v === "bigint" ? v.toString() : v)));
}

export function createKeeper(options: KeeperOptions) {
  const { publicClient, walletClient, factory, poolManager, stateView } = options;
  const maxOps = options.maxOps ?? 24n;
  if (maxOps < 9n) throw new Error("maxOps must be at least 9: the busiest level costs 9 operations");
  const logChunk = options.logChunk ?? 10_000n;
  const log = options.log ?? defaultLog;

  const hooks = new Map<Address, number>(); // hook => level spacing
  const pools = new Map<Hex, Pool>();
  /** Pools to check: they had activity, or a check couldn't finish (gas price, revert). */
  const dirty = new Set<Hex>();
  /** Levels a scan skipped, as `poolId:level`. */
  const skipped = new Map<string, { poolId: Hex; level: number }>();
  let nextBlock = options.startBlock;

  // -------------------------------------------------------------------------------------------------------------
  // Reading the chain
  // -------------------------------------------------------------------------------------------------------------

  async function readLogs() {
    // viem caches the block number for its polling interval; a stale head would skip the newest logs.
    const head = await publicClient.getBlockNumber({ cacheTime: 0 });
    for (let from = nextBlock; from <= head; from += logChunk) {
      const to = from + logChunk - 1n < head ? from + logChunk - 1n : head;

      const created = await publicClient.getLogs({
        address: factory,
        event: getAbiItem({ abi: tickTockFactoryAbi, name: "HookCreated" }),
        fromBlock: from,
        toBlock: to,
      });
      for (const l of created) hooks.set(l.args.hook!, Number(l.args.levelSpacing));

      if (hooks.size > 0) {
        const raw = await publicClient.getLogs({ address: [...hooks.keys()], fromBlock: from, toBlock: to });
        for (const l of parseEventLogs({ abi: tickTockHookAbi, logs: raw })) {
          if (l.eventName === "Deposit") await addPool(l.address, l.args.poolId);
          if (l.eventName === "LevelSkipped") queueSkipped(l.args.poolId, l.args.level);
          if ("poolId" in l.args) dirty.add(l.args.poolId as Hex);
        }
      }

      if (pools.size > 0) {
        const swaps = await publicClient.getLogs({
          address: poolManager,
          event: getAbiItem({ abi: poolManagerAbi, name: "Swap" }),
          args: { id: [...pools.keys()] },
          fromBlock: from,
          toBlock: to,
        });
        for (const s of swaps) dirty.add(s.args.id!);
      }
    }
    nextBlock = head + 1n;
  }

  async function addPool(hook: Address, poolId: Hex) {
    if (pools.has(poolId)) return;
    const p = await publicClient.readContract({ abi: tickTockHookAbi, address: hook, functionName: "getPool", args: [poolId] });
    const key = { currency0: p.currency0, currency1: p.currency1, fee: p.fee, tickSpacing: 1, hooks: hook };
    pools.set(poolId, { id: poolId, key, levelSpacing: hooks.get(hook) ?? 1 });
    log({ msg: "pool found", poolId, hook });
  }

  function queueSkipped(poolId: Hex, level: number) {
    skipped.set(`${poolId}:${level}`, { poolId, level });
  }

  // -------------------------------------------------------------------------------------------------------------
  // Acting
  // -------------------------------------------------------------------------------------------------------------

  /** The error name a simulation reverted with, if the hook's ABI knows it. */
  function revertName(error: unknown): string | undefined {
    if (!(error instanceof BaseError)) return undefined;
    const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
    return reverted instanceof ContractFunctionRevertedError ? reverted.data?.errorName : undefined;
  }

  /** Sends a simulated call unless the gas price is too high. Records `LevelSkipped` from its receipt. */
  async function send(action: Omit<Action, "status">, request: Parameters<typeof walletClient.writeContract>[0]) {
    if (options.dryRun) return finish({ ...action, status: "dry-run" });
    if (options.maxGasPriceWei !== undefined) {
      const gasPrice = await publicClient.getGasPrice();
      if (gasPrice > options.maxGasPriceWei) return finish({ ...action, status: "gas-price-too-high" });
    }
    const hash = await walletClient.writeContract(request);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    for (const l of parseEventLogs({ abi: tickTockHookAbi, logs: receipt.logs, eventName: "LevelSkipped" })) {
      queueSkipped(l.args.poolId, l.args.level);
    }
    return finish({ ...action, status: receipt.status === "success" ? "sent" : "reverted", hash, gasUsed: receipt.gasUsed });
  }

  const actions: Action[] = [];
  function finish(action: Action) {
    actions.push(action);
    log({ msg: action.kind, ...action });
    return action;
  }

  /** Flips crossed levels until none are left. False if it couldn't finish. */
  async function flipCrossed(pool: Pool): Promise<boolean> {
    for (let i = 0; i < MAX_FLIP_CROSSED_PER_RUN; ++i) {
      const { result: ops, request } = await publicClient.simulateContract({
        account: walletClient.account,
        abi: tickTockHookAbi,
        address: pool.key.hooks,
        functionName: "flipCrossed",
        args: [pool.key, maxOps],
      });
      if (ops === 0n) return true;
      const action = await send({ kind: "flipCrossed", poolId: pool.id, ops }, request);
      if (action.status !== "sent") return false;
    }
    return false;
  }

  /** Flips a level: a skipped one, or the one the price is inside. True when there's nothing left to do. */
  async function flipLevel(pool: Pool, level: number): Promise<boolean> {
    let request;
    try {
      ({ request } = await publicClient.simulateContract({
        account: walletClient.account,
        abi: tickTockHookAbi,
        address: pool.key.hooks,
        functionName: "flipLevel",
        args: [pool.key, level],
      }));
    } catch (error) {
      if (revertName(error) === "NothingToFlip") return true;
      throw error;
    }
    const action = await send({ kind: "flipLevel", poolId: pool.id, level }, request);
    return action.status === "sent";
  }

  /** The level the price is inside, if it's on the grid. */
  async function levelInside(pool: Pool): Promise<number | undefined> {
    const [, tick] = await publicClient.readContract({
      abi: stateViewAbi,
      address: stateView,
      functionName: "getSlot0",
      args: [pool.id],
    });
    const spacing = pool.levelSpacing;
    return ((tick % spacing) + spacing) % spacing === 0 ? tick : undefined;
  }

  async function runOnce(): Promise<Action[]> {
    actions.length = 0;
    await readLogs();

    // One failure never stops the others: the item stays queued for the next run.
    for (const poolId of [...dirty]) {
      const pool = pools.get(poolId);
      if (!pool) {
        dirty.delete(poolId);
        continue;
      }
      try {
        let done = await flipCrossed(pool);
        const inside = await levelInside(pool);
        if (done && inside !== undefined) done = await flipLevel(pool, inside);
        if (done) dirty.delete(poolId);
      } catch (error) {
        log({ msg: "pool check failed", poolId, error: String(error) });
      }
    }

    for (const [id, { poolId, level }] of [...skipped]) {
      const pool = pools.get(poolId);
      try {
        if (!pool || (await flipLevel(pool, level))) skipped.delete(id);
      } catch (error) {
        log({ msg: "skipped level failed", poolId, level, error: String(error) });
      }
    }
    return [...actions];
  }

  return {
    runOnce,
    /** For tests and monitoring. */
    state: () => ({ hooks: hooks.size, pools: pools.size, dirty: dirty.size, skipped: skipped.size, nextBlock }),
  };
}

export type Keeper = ReturnType<typeof createKeeper>;
