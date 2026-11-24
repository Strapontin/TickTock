import { type ChildProcess, spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { createWalletClient, getAbiItem, http } from "viem";
import { orderLevel, tickTockHookAbi } from "@ticktock/shared";
import { anvilAccount, type LocalChain, startLocalChain, stopProcess, trade, waitFor } from "@ticktock/shared/testing";

// The indexer against a local chain: its state must match what the hook returns, after a backfill and in realtime.

const ANVIL_PORT = 8645;
const PONDER_PORT = 42169;
const api = `http://127.0.0.1:${PONDER_PORT}`;
const indexerDir = resolve(fileURLToPath(new URL(".", import.meta.url)), "..");

let chain: LocalChain;
let ponder: ChildProcess | undefined;
let ponderLog = "";
let pgliteDir: string;

/** One order's worth (one base token) in token0 and token1. DeployTestnet's base has 18 decimals, its quote 6. */
function orderValues(c: LocalChain): { value0: bigint; value1: bigint } {
  const base = 10n ** 18n;
  const quote = BigInt(c.deployment.price) * 10n ** 6n;
  return c.deployment.pool.currency0 === c.deployment.tokens.base
    ? { value0: base, value1: quote }
    : { value0: quote, value1: base };
}

beforeAll(async () => {
  chain = await startLocalChain("e2e-indexer", ANVIL_PORT);
  const { value0, value1 } = orderValues(chain);
  // Up through the two best asks (two flips, one into a waiting bid: a merge), then down through the bids.
  await trade(chain, false, (value1 * 5n) / 2n);
  await trade(chain, true, value0 * 4n);

  pgliteDir = mkdtempSync(join(tmpdir(), "ticktock-pglite-"));
  ponder = spawn("npx", ["ponder", "start", "--schema", "e2e", "--port", String(PONDER_PORT)], {
    cwd: indexerDir,
    env: {
      ...process.env,
      TICKTOCK_DEPLOYMENT: chain.deploymentPath,
      PONDER_RPC_URL: chain.rpc,
      PONDER_PGLITE_DIRECTORY: pgliteDir,
      DATABASE_URL: "",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  ponder.stdout?.on("data", (d) => (ponderLog += d));
  ponder.stderr?.on("data", (d) => (ponderLog += d));
  try {
    await waitFor(async () => (await fetch(`${api}/ready`)).ok, 180_000, "ponder to be ready");
  } catch (e) {
    throw new Error(`${e}\n--- ponder log ---\n${ponderLog}`);
  }
}, 600_000);

afterAll(async () => {
  if (ponder) await stopProcess(ponder);
  await chain?.stop();
  if (pgliteDir) rmSync(pgliteDir, { recursive: true, force: true });
});

// ---------------------------------------------------------------------------------------------------------------
// The indexer's view, and the chain's
// ---------------------------------------------------------------------------------------------------------------

type Row = Record<string, string | number | boolean | null>;

async function query<T = Row>(table: string, fields: string): Promise<T[]> {
  const res = await fetch(`${api}/graphql`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ query: `{ ${table}(limit: 1000) { items { ${fields} } } }` }),
  });
  const body = (await res.json()) as { data?: Record<string, { items: T[] }>; errors?: unknown };
  if (!body.data) throw new Error(`graphql: ${JSON.stringify(body.errors)}`);
  return body.data[table]!.items;
}

/** Waits until the indexer has processed the chain's latest block. */
async function waitForIndexer() {
  const latest = await chain.publicClient.getBlockNumber();
  await waitFor(
    async () => {
      const status = (await (await fetch(`${api}/status`)).json()) as Record<string, { block: { number: number } }>;
      return BigInt(status.unichain?.block.number ?? 0) >= latest;
    },
    60_000,
    `the indexer to reach block ${latest}`,
  );
}

function read<T>(functionName: string, args: unknown[]): Promise<T> {
  return chain.publicClient.readContract({
    abi: tickTockHookAbi,
    address: chain.deployment.hook,
    functionName: functionName as never,
    args: args as never,
  }) as Promise<T>;
}

type Group = {
  liquidity: bigint;
  pending0: bigint;
  pending1: bigint;
  mergedInto: bigint;
  sellLevel: number;
  spreadIndex: number;
  isBid: boolean;
  totalShares: bigint;
};

async function checkAgainstChain() {
  const d = chain.deployment;
  const [groups, slots, positions, levels, flips] = await Promise.all([
    query("orderGroups", "id sellLevel spreadIndex isBid level liquidity pending0 pending1 totalShares mergedInto flips"),
    query("strategySlots", "poolId sellLevel spreadIndex isBid groupId"),
    query("positions", "owner groupId shares"),
    query("levels", "poolId level askLiquidity bidLiquidity"),
    query("flips", "id"),
  ]);

  // Every group the hook created is indexed, with the hook's amounts.
  const lastGroupId = await read<bigint>("lastGroupId", []);
  expect(groups.length).toBe(Number(lastGroupId));
  for (const row of groups) {
    const g = await read<Group>("getGroup", [BigInt(row.id as string)]);
    expect(row, `group ${row.id}`).toMatchObject({
      sellLevel: g.sellLevel,
      spreadIndex: g.spreadIndex,
      isBid: g.isBid,
      level: orderLevel(g.sellLevel, d.spreads[g.spreadIndex]!, g.isBid),
      liquidity: g.liquidity.toString(),
      pending0: g.pending0.toString(),
      pending1: g.pending1.toString(),
      totalShares: g.totalShares.toString(),
      mergedInto: g.mergedInto === 0n ? null : g.mergedInto.toString(),
    });
  }

  // The slots are exactly the live groups, each where the hook has it.
  for (const s of slots) {
    const level = orderLevel(s.sellLevel as number, d.spreads[s.spreadIndex as number]!, s.isBid as boolean);
    const onChain = await read<bigint>("slotGroup", [s.poolId, level, s.isBid, s.spreadIndex]);
    expect(onChain.toString(), `slot ${JSON.stringify(s)}`).toBe(s.groupId);
  }
  const live = groups.filter((g) => g.mergedInto === null && g.totalShares !== "0").map((g) => g.id);
  expect(slots.map((s) => s.groupId).sort()).toEqual(live.sort());

  // Every position, and every non-zero balance of the deployer, which made every deposit.
  for (const p of positions) {
    const shares = await read<bigint>("sharesOf", [p.owner, BigInt(p.groupId as string)]);
    expect(shares.toString(), `position ${JSON.stringify(p)}`).toBe(p.shares);
  }
  const held: string[] = [];
  for (let id = 1n; id <= lastGroupId; ++id) {
    if ((await read<bigint>("sharesOf", [anvilAccount.address, id])) > 0n) held.push(id.toString());
  }
  expect(positions.map((p) => p.groupId).sort()).toEqual(held.sort());

  for (const l of levels) {
    const onChain = await read<{ askLiquidity: bigint; bidLiquidity: bigint }>("getLevel", [l.poolId, l.level]);
    expect(l, `level ${l.level}`).toMatchObject({
      askLiquidity: onChain.askLiquidity.toString(),
      bidLiquidity: onChain.bidLiquidity.toString(),
    });
  }

  const flipLogs = await chain.publicClient.getLogs({
    address: d.hook,
    event: getAbiItem({ abi: tickTockHookAbi, name: "LevelFlipped" }),
    fromBlock: BigInt(d.startBlock),
  });
  expect(flips.length).toBe(flipLogs.length);
  return { groups, positions };
}

// ---------------------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------------------

describe("indexer", () => {
  test("matches the chain after a backfill", async () => {
    await waitForIndexer();
    const { groups } = await checkAgainstChain();
    expect(groups.some((g) => g.mergedInto !== null), "the buy merged a flipped ask into a waiting bid").toBe(true);
    expect(groups.some((g) => (g.flips as number) > 0)).toBe(true);
  });

  test("follows realtime activity, including a withdrawal that converts merged shares", async () => {
    const { groups, positions } = await checkAgainstChain();
    const absorbed = groups.find((g) => g.mergedInto !== null)!;
    const held = positions.find((p) => p.groupId === absorbed.id)!;

    const wallet = createWalletClient({ account: anvilAccount, transport: http(chain.rpc) });
    const hash = await wallet.writeContract({
      chain: null,
      abi: tickTockHookAbi,
      address: chain.deployment.hook,
      functionName: "withdraw",
      args: [BigInt(absorbed.id as string), BigInt(held.shares as string), anvilAccount.address, 2n ** 40n],
    });
    await chain.publicClient.waitForTransactionReceipt({ hash });
    const { value1 } = orderValues(chain);
    await trade(chain, false, value1 * 3n);

    await waitForIndexer();
    const after = await checkAgainstChain();
    expect(after.positions.some((p) => p.groupId === absorbed.id), "the converted shares left").toBe(false);
  });

  test("serves positions and the order book", async () => {
    const positions = (await (await fetch(`${api}/positions/${anvilAccount.address}`)).json()) as {
      position: Row;
      group: Row;
    }[];
    expect(positions.length).toBeGreaterThan(0);
    expect(positions.every((p) => p.group.id === p.position.groupId)).toBe(true);

    const book = (await (await fetch(`${api}/book/${chain.deployment.pool.id}`)).json()) as Row[];
    expect(book.length).toBeGreaterThan(0);
    expect(book.every((l) => l.askLiquidity !== "0" || l.bidLiquidity !== "0")).toBe(true);
    const ticks = book.map((l) => l.level as number);
    expect(ticks).toEqual([...ticks].sort((a, b) => a - b));

    expect((await fetch(`${api}/positions/not-an-address`)).status).toBe(400);
  });
});

