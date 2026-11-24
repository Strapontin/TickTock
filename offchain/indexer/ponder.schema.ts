import { index, onchainTable, primaryKey, relations } from "ponder";

// ---------------------------------------------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------------------------------------------

/** One hook per config (level spacing plus spread menu). */
export const hook = onchainTable("hook", (t) => ({
  address: t.hex().primaryKey(),
  configHash: t.hex().notNull(),
  levelSpacing: t.integer().notNull(),
  spreads: t.integer().array().notNull(),
  createdBlock: t.bigint().notNull(),
  createdAt: t.bigint().notNull(),
}));

export const pool = onchainTable(
  "pool",
  (t) => ({
    id: t.hex().primaryKey(),
    hook: t.hex().notNull(),
    currency0: t.hex().notNull(),
    currency1: t.hex().notNull(),
    fee: t.integer().notNull(),
    /** From the last indexed swap, so only for the deployment's pools. */
    sqrtPriceX96: t.bigint(),
    tick: t.integer(),
    createdBlock: t.bigint().notNull(),
    createdAt: t.bigint().notNull(),
  }),
  (t) => ({ hookIdx: index().on(t.hook) }),
);

/** A level's liquidity on each side: the order book. */
export const level = onchainTable(
  "level",
  (t) => ({
    poolId: t.hex().notNull(),
    level: t.integer().notNull(),
    askLiquidity: t.bigint().notNull(),
    bidLiquidity: t.bigint().notNull(),
    updatedBlock: t.bigint().notNull(),
  }),
  (t) => ({ pk: primaryKey({ columns: [t.poolId, t.level] }) }),
);

/**
 * A group: the users sharing one side of one strategy. Group ids are per hook. Amounts come from the hook's
 * `getGroup` at the end of the block of the last event that touched the group.
 */
export const orderGroup = onchainTable(
  "order_group",
  (t) => ({
    hook: t.hex().notNull(),
    id: t.bigint().notNull(),
    poolId: t.hex().notNull(),
    sellLevel: t.integer().notNull(),
    spreadIndex: t.integer().notNull(),
    spread: t.integer().notNull(),
    isBid: t.boolean().notNull(),
    /** Where its order sits now: the sell level, or the sell level minus the spread for a bid. */
    level: t.integer().notNull(),
    liquidity: t.bigint().notNull(),
    pending0: t.bigint().notNull(),
    pending1: t.bigint().notNull(),
    totalShares: t.bigint().notNull(),
    /** Set once the group is absorbed by a merge. Its holders' shares convert on their next withdrawal. */
    mergedInto: t.bigint(),
    flips: t.integer().notNull(),
    createdBlock: t.bigint().notNull(),
    updatedBlock: t.bigint().notNull(),
  }),
  (t) => ({ pk: primaryKey({ columns: [t.hook, t.id] }), poolIdx: index().on(t.poolId) }),
);

/** Which group holds each side of each strategy, as the hook's `slotGroup` would say. */
export const strategySlot = onchainTable(
  "strategy_slot",
  (t) => ({
    hook: t.hex().notNull(),
    poolId: t.hex().notNull(),
    sellLevel: t.integer().notNull(),
    spreadIndex: t.integer().notNull(),
    isBid: t.boolean().notNull(),
    groupId: t.bigint().notNull(),
  }),
  (t) => ({ pk: primaryKey({ columns: [t.hook, t.poolId, t.sellLevel, t.spreadIndex, t.isBid] }) }),
);

/** A user's shares in a group. Shares in an absorbed group stay here until the user's next withdrawal converts them. */
export const position = onchainTable(
  "position",
  (t) => ({
    hook: t.hex().notNull(),
    owner: t.hex().notNull(),
    groupId: t.bigint().notNull(),
    shares: t.bigint().notNull(),
  }),
  (t) => ({ pk: primaryKey({ columns: [t.hook, t.owner, t.groupId] }), ownerIdx: index().on(t.owner) }),
);

// ---------------------------------------------------------------------------------------------------------------
// History: one row per event, keyed by transaction hash and log index
// ---------------------------------------------------------------------------------------------------------------

// The column builders are only reachable through the signature of `onchainTable`.
type ColumnBuilders = Parameters<Extract<Parameters<typeof onchainTable>[1], (...args: never[]) => unknown>>[0];

const eventColumns = (t: ColumnBuilders) => ({
  id: t.text().primaryKey(),
  block: t.bigint().notNull(),
  timestamp: t.bigint().notNull(),
  transaction: t.hex().notNull(),
});

export const deposit = onchainTable("deposit", (t) => ({
  ...eventColumns(t),
  hook: t.hex().notNull(),
  poolId: t.hex().notNull(),
  groupId: t.bigint().notNull(),
  recipient: t.hex().notNull(),
  sender: t.hex().notNull(),
  sellLevel: t.integer().notNull(),
  spreadIndex: t.integer().notNull(),
  startWithToken0: t.boolean().notNull(),
  amount: t.bigint().notNull(),
  liquidity: t.bigint().notNull(),
  shares: t.bigint().notNull(),
}));

export const withdrawal = onchainTable("withdrawal", (t) => ({
  ...eventColumns(t),
  hook: t.hex().notNull(),
  groupId: t.bigint().notNull(),
  owner: t.hex().notNull(),
  recipient: t.hex().notNull(),
  shares: t.bigint().notNull(),
  amount0: t.bigint().notNull(),
  amount1: t.bigint().notNull(),
}));

export const flip = onchainTable("flip", (t) => ({
  ...eventColumns(t),
  hook: t.hex().notNull(),
  poolId: t.hex().notNull(),
  level: t.integer().notNull(),
  /** True when bids flipped into asks. */
  bids: t.boolean().notNull(),
  liquidity: t.bigint().notNull(),
  partialFill: t.boolean().notNull(),
}));

export const merge = onchainTable("merge", (t) => ({
  ...eventColumns(t),
  hook: t.hex().notNull(),
  survivor: t.bigint().notNull(),
  absorbed: t.bigint().notNull(),
  newShares: t.bigint().notNull(),
}));

export const skip = onchainTable("skip", (t) => ({
  ...eventColumns(t),
  hook: t.hex().notNull(),
  poolId: t.hex().notNull(),
  level: t.integer().notNull(),
  bids: t.boolean().notNull(),
}));

export const unplaced = onchainTable("unplaced", (t) => ({
  ...eventColumns(t),
  hook: t.hex().notNull(),
  groupId: t.bigint().notNull(),
  level: t.integer().notNull(),
  amount: t.bigint().notNull(),
}));

export const swap = onchainTable(
  "swap",
  (t) => ({
    ...eventColumns(t),
    poolId: t.hex().notNull(),
    sender: t.hex().notNull(),
    amount0: t.bigint().notNull(),
    amount1: t.bigint().notNull(),
    sqrtPriceX96: t.bigint().notNull(),
    liquidity: t.bigint().notNull(),
    tick: t.integer().notNull(),
    fee: t.integer().notNull(),
  }),
  (t) => ({ poolIdx: index().on(t.poolId) }),
);

// ---------------------------------------------------------------------------------------------------------------
// Relations, for the GraphQL API
// ---------------------------------------------------------------------------------------------------------------

export const hookRelations = relations(hook, ({ many }) => ({ pools: many(pool) }));

export const poolRelations = relations(pool, ({ one, many }) => ({
  hookRow: one(hook, { fields: [pool.hook], references: [hook.address] }),
  groups: many(orderGroup),
  levels: many(level),
  swaps: many(swap),
}));

export const levelRelations = relations(level, ({ one }) => ({
  pool: one(pool, { fields: [level.poolId], references: [pool.id] }),
}));

export const orderGroupRelations = relations(orderGroup, ({ one, many }) => ({
  pool: one(pool, { fields: [orderGroup.poolId], references: [pool.id] }),
  positions: many(position),
}));

export const positionRelations = relations(position, ({ one }) => ({
  group: one(orderGroup, { fields: [position.hook, position.groupId], references: [orderGroup.hook, orderGroup.id] }),
}));

export const swapRelations = relations(swap, ({ one }) => ({
  pool: one(pool, { fields: [swap.poolId], references: [pool.id] }),
}));
