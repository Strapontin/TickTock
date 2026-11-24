import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { createPublicClient, createWalletClient, defineChain, http, parseEventLogs } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { getSqrtPriceAtTick, levelBounds, tickTockHookAbi } from "@ticktock/shared";
import { ANVIL_KEEPER_KEY, deposit, type LocalChain, slot0, startLocalChain, swapTo } from "@ticktock/shared/testing";
import { type Action, createKeeper, type KeeperOptions } from "../src/keeper.js";

// The keeper against a local chain with TickTock deployed and seeded: 8 asks above the price, 8 bids below, one
// level (10 ticks) apart, cycling through the 5 spreads. `mid` is the best bid's level.

const ANVIL_PORT = 8745;
let chain: LocalChain;
let mid: number;
let oneOrder0: bigint; // one order's worth of token0

beforeAll(async () => {
  chain = await startLocalChain("e2e-keeper", ANVIL_PORT);
  mid = (await slot0(chain)).tick - 10; // the pool was created at the best ask's price
  const base = 10n ** 18n;
  const quote = BigInt(chain.deployment.price) * 10n ** 6n;
  oneOrder0 = chain.deployment.pool.currency0 === chain.deployment.tokens.base ? base : quote;
}, 600_000);

afterAll(async () => {
  await chain?.stop();
});

function makeKeeper(overrides: Partial<KeeperOptions> = {}) {
  const d = chain.deployment;
  const viemChain = defineChain({
    id: d.chainId,
    name: "local",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [chain.rpc] } },
  });
  const transport = http(chain.rpc);
  return createKeeper({
    publicClient: createPublicClient({ chain: viemChain, transport }),
    walletClient: createWalletClient({ chain: viemChain, transport, account: privateKeyToAccount(ANVIL_KEEPER_KEY) }),
    factory: d.factory,
    poolManager: d.poolManager,
    stateView: d.stateView,
    startBlock: BigInt(d.startBlock),
    maxOps: BigInt(d.maxOpsPerSwap),
    log: () => {},
    ...overrides,
  });
}

async function askLiquidity(level: number): Promise<bigint> {
  const l = await chain.publicClient.readContract({
    abi: tickTockHookAbi,
    address: chain.deployment.hook,
    functionName: "getLevel",
    args: [chain.deployment.pool.id, level],
  });
  return l.askLiquidity;
}

/** Moves the price 95% of the way through the ask at `level`. */
async function sell95PercentOf(level: number) {
  const { lower, upper } = levelBounds(level);
  await swapTo(chain, upper - (upper - lower) / 20n);
}

const sent = (actions: Action[]) => actions.filter((a) => a.status === "sent");

describe("keeper", () => {
  const keeper = { current: undefined as ReturnType<typeof createKeeper> | undefined };

  test("finds the pool and sends nothing when nothing needs flipping", async () => {
    keeper.current = makeKeeper();
    expect(await keeper.current.runOnce()).toEqual([]);
    expect(keeper.current.state()).toMatchObject({ hooks: 1, pools: 1, dirty: 0, skipped: 0 });
  });

  test("finishes what a swap's budget couldn't flip", async () => {
    // Four levels with all 5 spreads above the seeded asks: crossing everything takes 8 x 2 + 4 x 6 = 40 operations.
    for (let level = mid + 90; level <= mid + 120; level += 10) {
      for (let k = 0; k < 5; ++k) await deposit(chain, level, k, true, oneOrder0);
    }
    await swapTo(chain, getSqrtPriceAtTick(mid + 125));

    const asks = Array.from({ length: 12 }, (_, i) => mid + 10 * (i + 1));
    const left = (await Promise.all(asks.map(askLiquidity))).filter((l) => l > 0n).length;
    expect(left, "the swap's budget of 24 left crossed levels").toBeGreaterThan(0);

    const actions = await keeper.current!.runOnce();
    expect(sent(actions).some((a) => a.kind === "flipCrossed")).toBe(true);
    for (const level of asks) expect(await askLiquidity(level), `ask at ${level}`).toBe(0n);
    expect(keeper.current!.state().dirty).toBe(0);
  });

  test("flips a level a scan skipped as small", async () => {
    // Dust next to an order 100,000 times larger: the swap skips the dust (DESIGN.md section 5.3).
    await deposit(chain, mid + 130, 0, true, oneOrder0 / 10_000n);
    await deposit(chain, mid + 140, 0, true, oneOrder0 * 10n);
    const receipt = await swapTo(chain, getSqrtPriceAtTick(mid + 145));
    const skips = parseEventLogs({ abi: tickTockHookAbi, logs: receipt.logs, eventName: "LevelSkipped" });
    expect(skips.map((s) => s.args.level)).toEqual([mid + 130]);
    expect(await askLiquidity(mid + 130)).toBeGreaterThan(0n);

    const actions = await keeper.current!.runOnce();
    expect(sent(actions).length).toBeGreaterThan(0);
    expect(await askLiquidity(mid + 130)).toBe(0n);
    expect(keeper.current!.state()).toMatchObject({ dirty: 0, skipped: 0 });
  });

  test("flips the level the price stopped inside once 90% is sold", async () => {
    await deposit(chain, mid + 160, 0, true, oneOrder0);
    await sell95PercentOf(mid + 160);

    const actions = await keeper.current!.runOnce();
    const flip = sent(actions).find((a) => a.kind === "flipLevel");
    expect(flip?.level).toBe(mid + 160);
    expect(await askLiquidity(mid + 160)).toBe(0n);

    const r = await chain.publicClient.getTransactionReceipt({ hash: flip!.hash! });
    const flipped = parseEventLogs({ abi: tickTockHookAbi, logs: r.logs, eventName: "LevelFlipped" });
    expect(flipped[0]?.args.partialFill).toBe(true);
  });

  test("leaves a level under 90% sold alone", async () => {
    await deposit(chain, mid + 180, 0, true, oneOrder0);
    const { lower, upper } = levelBounds(mid + 180);
    await swapTo(chain, lower + (upper - lower) / 2n);
    expect(sent(await keeper.current!.runOnce())).toEqual([]);
    expect(await askLiquidity(mid + 180)).toBeGreaterThan(0n);
  });

  test("simulates only in a dry run, and waits while gas is too expensive", async () => {
    await sell95PercentOf(mid + 180);

    const dry = await makeKeeper({ dryRun: true }).runOnce();
    expect(dry.map((a) => a.status)).toContain("dry-run");
    const capped = await makeKeeper({ maxGasPriceWei: 1n }).runOnce();
    expect(capped.map((a) => a.status)).toContain("gas-price-too-high");
    expect(await askLiquidity(mid + 180), "nothing was sent").toBeGreaterThan(0n);

    const actions = await keeper.current!.runOnce();
    expect(sent(actions).map((a) => a.level)).toContain(mid + 180);
    expect(await askLiquidity(mid + 180)).toBe(0n);
  });

  test("refuses a budget the busiest level can't fit in", () => {
    expect(() => makeKeeper({ maxOps: 8n })).toThrow(/at least 9/);
  });
});
