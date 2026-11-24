import { type Context, ponder } from "ponder:registry";
import {
  deposit,
  flip,
  hook,
  level,
  merge,
  orderGroup,
  pool,
  position,
  skip,
  strategySlot,
  swap,
  unplaced,
  withdrawal,
} from "ponder:schema";
import { flipDestination, orderLevel, sellLevelOf, tickTockHookAbi } from "@ticktock/shared";
import type { Address, Hex } from "viem";

// How state is kept:
// - Which group holds which strategy slot follows the events exactly: a flip moves a strategy's group to its other
//   slot, and the survivor of a merge ends up in the destination (DESIGN.md sections 5.2 and 6).
// - Amounts (liquidity, pending tokens, shares) are read from the hook at the end of the event's block, so they are
//   always what the hook stores, never recomputed here.

type Meta = { id: string; block: bigint; timestamp: bigint; transaction: Hex };

function meta(event: {
  block: { number: bigint; timestamp: bigint };
  transaction: { hash: Hex };
  log: { logIndex: number };
}): Meta {
  return {
    id: `${event.transaction.hash}-${event.log.logIndex}`,
    block: event.block.number,
    timestamp: event.block.timestamp,
    transaction: event.transaction.hash,
  };
}

async function spreadsOf(context: Context, hookAddress: Address): Promise<number[]> {
  const row = await context.db.find(hook, { address: hookAddress });
  if (!row) throw new Error(`hook ${hookAddress} not indexed`);
  return row.spreads;
}

/** Writes the group as the hook stores it, keeping the fields only events know (merges, flip count). */
async function refreshGroup(context: Context, hookAddress: Address, groupId: bigint, block: bigint) {
  const g = await context.client.readContract({
    abi: tickTockHookAbi,
    address: hookAddress,
    functionName: "getGroup",
    args: [groupId],
  });
  const spreads = await spreadsOf(context, hookAddress);
  const spread = spreads[g.spreadIndex] ?? 0;
  const values = {
    poolId: g.poolId,
    sellLevel: g.sellLevel,
    spreadIndex: g.spreadIndex,
    spread,
    isBid: g.isBid,
    level: orderLevel(g.sellLevel, spread, g.isBid),
    liquidity: g.liquidity,
    pending0: g.pending0,
    pending1: g.pending1,
    totalShares: g.totalShares,
    updatedBlock: block,
  };
  await context.db
    .insert(orderGroup)
    .values({ hook: hookAddress, id: groupId, ...values, mergedInto: null, flips: 0, createdBlock: block })
    .onConflictDoUpdate(values);
  return values;
}

async function refreshLevel(context: Context, hookAddress: Address, poolId: Hex, levelTick: number, block: bigint) {
  const l = await context.client.readContract({
    abi: tickTockHookAbi,
    address: hookAddress,
    functionName: "getLevel",
    args: [poolId, levelTick],
  });
  const values = { askLiquidity: l.askLiquidity, bidLiquidity: l.bidLiquidity, updatedBlock: block };
  await context.db
    .insert(level)
    .values({ poolId, level: levelTick, ...values })
    .onConflictDoUpdate(values);
}

async function addShares(context: Context, hookAddress: Address, owner: Address, groupId: bigint, delta: bigint) {
  const key = { hook: hookAddress, owner, groupId };
  const row = await context.db.find(position, key);
  const shares = (row?.shares ?? 0n) + delta;
  if (shares < 0n) throw new Error(`negative shares for ${owner} in group ${groupId}`);
  if (shares === 0n) {
    if (row) await context.db.delete(position, key);
    return;
  }
  await context.db.insert(position).values({ ...key, shares }).onConflictDoUpdate({ shares });
}

// ---------------------------------------------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------------------------------------------

ponder.on("TickTockFactory:HookCreated", async ({ event, context }) => {
  await context.db.insert(hook).values({
    address: event.args.hook,
    configHash: event.args.configHash,
    levelSpacing: event.args.levelSpacing,
    spreads: [...event.args.spreads],
    createdBlock: event.block.number,
    createdAt: event.block.timestamp,
  });
});

// ---------------------------------------------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------------------------------------------

ponder.on("TickTockHook:Deposit", async ({ event, context }) => {
  const hookAddress = event.log.address;
  const { poolId, groupId, recipient, sellLevel, spreadIndex, startWithToken0, shares } = event.args;

  // The first deposit creates the pool.
  if (!(await context.db.find(pool, { id: poolId }))) {
    const p = await context.client.readContract({
      abi: tickTockHookAbi,
      address: hookAddress,
      functionName: "getPool",
      args: [poolId],
    });
    await context.db.insert(pool).values({
      id: poolId,
      hook: hookAddress,
      currency0: p.currency0,
      currency1: p.currency1,
      fee: p.fee,
      createdBlock: event.block.number,
      createdAt: event.block.timestamp,
    });
  }

  const g = await refreshGroup(context, hookAddress, groupId, event.block.number);
  const slot = { hook: hookAddress, poolId, sellLevel, spreadIndex, isBid: !startWithToken0 };
  await context.db.insert(strategySlot).values({ ...slot, groupId }).onConflictDoUpdate({ groupId });
  await addShares(context, hookAddress, recipient, groupId, shares);
  await refreshLevel(context, hookAddress, poolId, g.level, event.block.number);

  await context.db.insert(deposit).values({ ...meta(event), hook: hookAddress, ...event.args });
});

ponder.on("TickTockHook:Withdraw", async ({ event, context }) => {
  const hookAddress = event.log.address;
  const { groupId, owner, shares } = event.args;

  await addShares(context, hookAddress, owner, groupId, -shares);
  const g = await refreshGroup(context, hookAddress, groupId, event.block.number);
  // The last holder out frees the group's slot.
  if (g.totalShares === 0n) {
    const slot = { hook: hookAddress, poolId: g.poolId, sellLevel: g.sellLevel, spreadIndex: g.spreadIndex, isBid: g.isBid };
    const row = await context.db.find(strategySlot, slot);
    if (row?.groupId === groupId) await context.db.delete(strategySlot, slot);
  }
  await refreshLevel(context, hookAddress, g.poolId, g.level, event.block.number);

  await context.db.insert(withdrawal).values({ ...meta(event), hook: hookAddress, ...event.args });
});

/** A withdrawal from an absorbed group converts the owner's shares into the survivor's first. */
ponder.on("TickTockHook:SharesConverted", async ({ event, context }) => {
  const hookAddress = event.log.address;
  const { owner, fromGroup, toGroup, fromShares, toShares } = event.args;
  await addShares(context, hookAddress, owner, fromGroup, -fromShares);
  await addShares(context, hookAddress, owner, toGroup, toShares);
  await refreshGroup(context, hookAddress, fromGroup, event.block.number);
});

/** Emitted during a flip, before its `LevelFlipped`. */
ponder.on("TickTockHook:GroupsMerged", async ({ event, context }) => {
  const hookAddress = event.log.address;
  const { survivor, absorbed } = event.args;
  await refreshGroup(context, hookAddress, absorbed, event.block.number);
  await context.db.update(orderGroup, { hook: hookAddress, id: absorbed }).set({ mergedInto: survivor });
  await refreshGroup(context, hookAddress, survivor, event.block.number);

  await context.db.insert(merge).values({ ...meta(event), hook: hookAddress, ...event.args });
});

ponder.on("TickTockHook:LevelFlipped", async ({ event, context }) => {
  const hookAddress = event.log.address;
  const { poolId, level: levelTick, bids } = event.args;
  const spreads = await spreadsOf(context, hookAddress);

  for (const [k, spread] of spreads.entries()) {
    const sellLevel = sellLevelOf(levelTick, spread, bids);
    const source = { hook: hookAddress, poolId, sellLevel, spreadIndex: k, isBid: bids };
    const moved = await context.db.find(strategySlot, source);
    if (!moved) continue;
    await context.db.delete(strategySlot, source);

    // The group moves to its strategy's other side, unless a merge absorbed it into the group waiting there.
    const g = await context.db.find(orderGroup, { hook: hookAddress, id: moved.groupId });
    const survivor = g?.mergedInto ?? moved.groupId;
    await context.db
      .insert(strategySlot)
      .values({ ...source, isBid: !bids, groupId: survivor })
      .onConflictDoUpdate({ groupId: survivor });

    await refreshGroup(context, hookAddress, moved.groupId, event.block.number);
    await context.db
      .update(orderGroup, { hook: hookAddress, id: moved.groupId })
      .set((row) => ({ flips: row.flips + 1 }));
    if (survivor !== moved.groupId) await refreshGroup(context, hookAddress, survivor, event.block.number);
    await refreshLevel(context, hookAddress, poolId, flipDestination(levelTick, spread, bids), event.block.number);
  }
  await refreshLevel(context, hookAddress, poolId, levelTick, event.block.number);

  await context.db.insert(flip).values({ ...meta(event), hook: hookAddress, ...event.args });
});

ponder.on("TickTockHook:LevelSkipped", async ({ event, context }) => {
  await context.db.insert(skip).values({ ...meta(event), hook: event.log.address, ...event.args });
});

ponder.on("TickTockHook:AmountUnplaced", async ({ event, context }) => {
  await context.db.insert(unplaced).values({ ...meta(event), hook: event.log.address, ...event.args });
});

// ---------------------------------------------------------------------------------------------------------------
// Swaps on the deployment's pools
// ---------------------------------------------------------------------------------------------------------------

ponder.on("PoolManager:Swap", async ({ event, context }) => {
  const { id, sender, amount0, amount1, sqrtPriceX96, liquidity, tick, fee } = event.args;
  await context.db
    .insert(swap)
    .values({ ...meta(event), poolId: id, sender, amount0, amount1, sqrtPriceX96, liquidity, tick, fee });
  if (await context.db.find(pool, { id })) {
    await context.db.update(pool, { id }).set({ sqrtPriceX96, tick });
  }
});
