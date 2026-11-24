/**
 * A strategy is a sell level S and a spread index k: it asks at S and bids at S - spreads[k] (DESIGN.md section 2).
 * Each strategy has two slots, one per side, each holding at most one group.
 */

/** The level a strategy's order sits at on one side. */
export function orderLevel(sellLevel: number, spread: number, isBid: boolean): number {
  return isBid ? sellLevel - spread : sellLevel;
}

/** The sell level of the strategy whose order sits at `level` on one side. */
export function sellLevelOf(level: number, spread: number, isBid: boolean): number {
  return isBid ? level + spread : level;
}

/** Where a flip of `level` sends spread k's group: asks become bids `spread` lower, bids become asks `spread` higher. */
export function flipDestination(level: number, spread: number, bids: boolean): number {
  return bids ? level + spread : level - spread;
}
