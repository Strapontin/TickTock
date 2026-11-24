import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { and, asc, client, eq, graphql, gt, or, replaceBigInts } from "ponder";

const app = new Hono();

app.use("/graphql", graphql({ db, schema }));
app.use("/sql/*", client({ db, schema }));

/** Amounts are bigints; JSON carries them as decimal strings. */
function json(value: unknown) {
  return new Response(JSON.stringify(replaceBigInts(value, (v) => v.toString())), {
    headers: { "content-type": "application/json" },
  });
}

function isHex(value: string, bytes: number): value is `0x${string}` {
  return new RegExp(`^0x[0-9a-fA-F]{${bytes * 2}}$`).test(value);
}

/**
 * A user's positions, each with its group. A position in an absorbed group (`mergedInto` set) is worth its share of
 * the survivor: the hook's `positionOf` gives the live value.
 */
app.get("/positions/:owner", async (c) => {
  const owner = c.req.param("owner");
  if (!isHex(owner, 20)) return c.json({ error: "owner must be an address" }, 400);
  const rows = await db
    .select({ position: schema.position, group: schema.orderGroup })
    .from(schema.position)
    .innerJoin(
      schema.orderGroup,
      and(eq(schema.position.hook, schema.orderGroup.hook), eq(schema.position.groupId, schema.orderGroup.id)),
    )
    .where(eq(schema.position.owner, owner.toLowerCase() as `0x${string}`));
  return json(rows);
});

/** A pool's order book: every level with liquidity on either side, lowest first. */
app.get("/book/:poolId", async (c) => {
  const poolId = c.req.param("poolId");
  if (!isHex(poolId, 32)) return c.json({ error: "poolId must be 32 bytes" }, 400);
  const rows = await db
    .select()
    .from(schema.level)
    .where(
      and(
        eq(schema.level.poolId, poolId.toLowerCase() as `0x${string}`),
        or(gt(schema.level.askLiquidity, 0n), gt(schema.level.bidLiquidity, 0n)),
      ),
    )
    .orderBy(asc(schema.level.level));
  return json(rows);
});

export default app;
