# TickTock: design spec

Status: draft for review. Nothing is implemented yet.

TickTock is a Uniswap v4 hook for double-sided limit orders. A user deposits one token and picks two prices. The hook sells at the high price, buys back at the low price, and repeats this forever, compounding everything. The hook is the only liquidity provider in its pools. Routers and arbitrage bots fill the orders.

## 1. Decisions

| Topic | Decision |
|---|---|
| Liquidity in TickTock pools | Only the hook's. `beforeAddLiquidity` reverts for everyone else. |
| Pairs and chains | Any pair, including native ETH, on any chain where v4 runs. |
| Pool creation | The hook creates the pool on the first deposit for a pair and fee, at that order's price. Calling `initialize` directly is refused. |
| Pool fee | Any static fee, chosen by the first depositor. Dynamic fees are rejected. |
| Tick spacing | Always 1. Each order is a one-tick range. |
| Strategy | A sell price plus a spread picked from a fixed menu. It repeats until the user withdraws. |
| Profit | Compounded. Each flip re-posts everything, LP fees included. |
| Starting token | Either one: token0 starts with the sell, token1 starts with the buy. |
| Configs | A factory deploys one hook per config (spread menu plus level spacing). Anyone can deploy a config; duplicates are refused. |
| Donations | Blocked. |
| Protocol fee | None. |
| Admin | None. No owner, no pause, no upgrades. |
| User shares | Balances inside the hook. Not transferable in v1. |

## 2. Vocabulary

Prices are always token1 per token0, the v4 convention. The front-end converts them for display.

- **Config**: `levelSpacing` (ticks, ≥ 1) plus `spreads`: 1 to 8 values in ticks, strictly increasing, each a positive multiple of `levelSpacing`. Each config has exactly one hook contract.
- **Level**: a tick `L` with `L % levelSpacing == 0`. Its range is `[L, L+1)`. An order at level `L` trades at about `price(L) ≈ 1.0001^L`, give or take 0.01%.
- **Ask**: an order holding token0 at a level above the price. It sells token0 when the price rises through it.
- **Bid**: an order holding token1 at a level below the price. It buys token0 when the price falls through it.
- **Strategy**: `(sellLevel S, spreadIndex k)`. It asks at `S`, then bids at `B = S - spreads[k]`, then asks at `S`, and so on.
- **Slot**: one side of a strategy: `ask(S, k)` sits at level `S`, `bid(S, k)` sits at level `B`. A level holds at most one ask slot and one bid slot per spread, so at most 2 × 8 slots.
- **Group**: the users sharing a slot, tracked with shares. A slot has at most one group at a time.
- **Flip**: when a level is fully crossed, its slots move to their opposite slots.
- **Liquidity operation**: one `modifyLiquidity` call. The per-swap budget is counted in these.

## 3. Contracts

### 3.1 `TickTockFactory` (one per chain)

- Constructor: `(IPoolManager poolManager, uint16 maxOpsPerSwap)`. It deploys the hook implementation once.
  - `maxOpsPerSwap` is the most liquidity operations one swap's `afterSwap` may spend. It's chosen per chain from the gas measurements: higher on L2s, lower on mainnet.
  - It must be at least 9 (1 removal plus 8 additions), so that the busiest possible level fits in one swap.
- `createHook(uint24 levelSpacing, int24[] spreads, bytes32 salt) returns (address hook)`:
  - Validates the config (section 2) and refuses it if `configHash = keccak256(levelSpacing, spreads)` already has a hook.
  - Predicts the clone address and requires its low 14 bits to match the hook's permissions exactly (section 3.2). Otherwise it reverts with `InvalidHookAddress`.
  - Deploys a minimal clone of the implementation with immutable args (`poolManager`, `maxOpsPerSwap`, `levelSpacing`, `spreads`), using Solady `LibClone.cloneDeterministic`.
  - Emits `HookCreated(configHash, hook, levelSpacing, spreads)`.
- Views:
  - `hookOf(configHash)`.
  - `predictHookAddress(levelSpacing, spreads, salt)`, used by the salt-mining script. A valid salt takes on average 16,384 tries off-chain, a few seconds.
- If someone front-runs a `createHook` with the same salt and config, they deploy the same hook at the same address, so it does no harm.

Clones cost about 100k gas to deploy instead of several million for a full contract. In exchange, each hook call pays a small `delegatecall` overhead, roughly 3k gas per swap.

Because the budget is counted in liquidity operations rather than levels, every config gets the same worst-case gas per swap, whatever the size of its menu.

### 3.2 `TickTockHook` (one per config)

Permissions, which must match the address bits exactly:

| Flag | Why |
|---|---|
| `beforeInitialize` | Always revert. The hook's own calls never reach it (v4 `noSelfCall`), so only the hook can create pools. Nobody can create a pool at a hostile starting price. |
| `beforeAddLiquidity` | Always revert, so outside LPs are blocked. |
| `afterSwap` | Flip the crossed levels. |
| `beforeDonate` | Always revert. A donation could inflate a group's pending balance and distort its share price. |

All other flags are off, including every return-delta flag.

User functions:

```solidity
function deposit(
    PoolKey calldata key,
    int24 sellLevel,
    uint8 spreadIndex,
    bool startWithToken0,   // true: ask at sellLevel. false: bid at sellLevel - spreads[k]
    uint128 amount,
    uint256 minShares,      // protects against a changed share price
    address recipient,
    uint256 deadline
) external payable returns (uint256 groupId, uint256 shares);

function withdraw(uint256 groupId, uint256 shares, address recipient, uint256 deadline)
    external returns (uint256 amount0, uint256 amount1);

// All permissionless:
function settle(PoolKey calldata key, uint256 maxOps) external;        // levels the swap budget didn't reach
function settleLevel(PoolKey calldata key, int24 level) external;      // one skipped or mostly-filled level
function movePrice(PoolKey calldata key, uint160 targetSqrtPrice) external; // through empty space only
```

Views: `positionOf(user, groupId)` (current token amounts), `getLevel`, `getGroup`, `resolveGroup(groupId)` (follows a merge, see section 6).

## 4. Storage (per pool)

```
Level  { uint128 askLiquidity; uint128 bidLiquidity; uint8 askMask; uint8 bidMask;
         uint256 feeGrowth0X128; uint256 feeGrowth1X128; }
Group  { uint128 liquidity; uint128 totalShares; uint128 pending0; uint128 pending1;
         uint256 feeGrowthLast0X128; uint256 feeGrowthLast1X128;
         uint64 mergedInto; uint192 mergeRateX96; slot location }

levels[poolId][L]            -> Level
slotGroup[poolId][slotKey]   -> groupId
groups[groupId]              -> Group    (ids only increase, so a lower id is an older group)
shares[user][groupId]        -> uint256
askBitmap[poolId], bidBitmap[poolId]   levels holding asks or bids, compressed by levelSpacing
askCursor[poolId], bidCursor[poolId]   where the next scan starts (section 5.3)
```

- The hook owns **one** v4 position per level: `(hook, L, L+1, salt = 0)`. Its liquidity is `askLiquidity + bidLiquidity`.
- The masks record which spreads have a non-empty slot at that level. That way a flip only visits the slots that exist.
- `pending0` and `pending1` are tokens owned by a group but not inside a position. They are fees, fees in the token the group doesn't currently hold, and amounts that couldn't be placed (sections 5.2 and 5.4). The hook holds them as ERC-6909 claims on the PoolManager.

## 5. Swaps and flips

### 5.1 When a level counts as crossed

Crossing is decided from `sqrtPrice`, not the tick, which avoids edge cases at range boundaries.

- Asks at `L` are fully converted to token1 when `sqrtPrice ≥ sqrtPrice(L+1)`.
- Bids at `L` are fully converted to token0 when `sqrtPrice ≤ sqrtPrice(L)`.

If the price stops inside `[L, L+1)`, the level is partly filled and `afterSwap` doesn't flip it. `settleLevel` can flip it once it's mostly filled (section 5.4).

### 5.2 Flipping a level (asks at `L`, price moved up; bids work the same way in reverse)

1. Remove `askLiquidity` from the level's position. The result is the principal in token1 plus fees in both tokens. The fees go into the level's fee growth, using the liquidity the level had before the removal.
2. For each spread `k` in `askMask`, for its group `g`:
   - Credit `g` its fees from the level's fee growth into `pending0` and `pending1`.
   - `g` gets `principal1 × g.liquidity / askLiquidity`, plus `g.pending1` (compounding).
3. For each `k`, add the token1 amount as liquidity at `B = L - spreads[k]`, one liquidity operation per destination level.
   - Any fees collected while touching `B` first go into `B`'s fee growth, credited to the slots already there.
   - Before adding, check the destination ticks against v4's per-tick liquidity limit. If the amount doesn't fit, it stays in `g`'s pending tokens instead.
4. Place `g` in slot `bid(L, k)` at `B`:
   - If that slot is empty, `g` just moves there. Its shares don't change.
   - Otherwise the two groups **merge** (section 6).
5. Update masks, totals, bitmaps and cursors.
6. Settle the hook's own balance changes. The removal and the additions are in the same token and nearly cancel out. What's left (fees, rounding dust, amounts that didn't fit) is minted to the hook as ERC-6909 claims. No tokens move.

Cost per crossed level: 1 removal, at most K additions (K = number of spreads in the menu), and up to 2K group updates. **This does not depend on how many users or deposits are at that level.**

No chain reactions: the price only moves one way during a swap, and re-posted orders always land behind it, so the same swap can't fill them.

**Rule: `afterSwap` never reverts because of order state.** If it could, a griefer could set up orders so that every swap through a level reverts. Anything that can't be done right away is left for later (pending tokens, an unflipped level) instead.

### 5.3 Budget, skipping and cursors

- **Budget.** `afterSwap` spends at most `maxOpsPerSwap` liquidity operations, starting from the level nearest the price where the swap began. A level is flipped completely or not at all.
- **Skipping tiny levels.** A crossed level that is small compared to the swap is skipped: it costs one storage read instead of a flip.
  - "Small" means its size, measured in the token the swapper paid, is below `swapInput / skipDivisor`. `skipDivisor` starts at `2 × maxOpsPerSwap` and will be tuned with the gas tests.
  - So dust can't use up the budget. Using it up takes orders big enough compared to the swap, which means real capital in orders that actually trade.
  - Skipped levels can be flipped by anyone with `settleLevel`.
- **Leftovers.** Levels the budget didn't reach stay crossed but unflipped. They're picked up by the next swap in the same direction, or by anyone calling `settle()`.
- **No loss from a late flip.** A level that wasn't flipped is still a normal position. If the price comes back, it simply un-fills (it buys back at the same price). The user misses a trade but loses nothing.
- **Cursors** (the bid cursor mirrors the ask cursor):
  - On pool creation, both cursors are set to the starting tick.
  - After an upward price move, `askCursor` is set to the first level the budget didn't reach, or to the current tick if there is none. Skipped levels are passed over.
  - After a downward price move, `askCursor = min(askCursor, current tick)`.
  - The hook's own price moves (deposit nudges, `movePrice`) update the cursors the same way. They skip `afterSwap`, so this is done in the hook's own code.
- The scan reads one bitmap word per 256 levels. That is no more than the PoolManager already read to move the price that far, so a swapper's cost grows with the distance they moved the price.

### 5.4 `settleLevel` and mostly-filled levels

A bot can stop its swap just before the end of the last level, filling 99.99% of it, so it never pays for that level's flip. Without a fix, the level stays unflipped. If the price comes back, the order un-fills: the bot got a free option, and the user misses the round trip.

`settleLevel(key, L)` handles this. Anyone can call it, typically the order's owner or a bot run by the front-end.

- If the level is fully crossed (a skipped level, or one the budget didn't reach), it flips as in section 5.2.
- If the price is inside the level, it flips once at least `partialFlipThreshold` of the level's starting token has been sold. That threshold starts at 90% and will be tuned in tests.
  - The unsold remainder goes to each group's pending tokens and is re-posted when the group comes back to that side.
- A bot that stops before the threshold to dodge this gives up the rest of that level's trade. That's only worth it on tiny levels.

## 6. Shares and merges

- **Shares.** Inside a slot, liquidity is a fair measure of value: same range, same token. A deposit of `ΔL` mints `ΔL × totalShares / value` shares.
  - `value` is the group's liquidity plus its pending tokens converted to liquidity at the level's price. That price comes from tick math, not the pool's live price, so it can't be manipulated.
  - Virtual shares and rounding in favor of existing holders protect against the share-inflation attack. Blocking donations removes the main way to inflate a group's value for free.
- **When merges happen.** Alice asks at 1000 with spread k, and Bob bids at 900 with the same spread. That's the same strategy on opposite sides, so they're two groups. When Alice's group flips to 900, Bob's group is already in that slot, and the two merge.
- **How a merge works.**
  1. The waiting group's pending tokens in the slot's own token are compounded into the same liquidity operation.
  2. Each group is valued as liquidity plus its other pending tokens, converted at the level's price.
  3. **The older group (lower id) survives** and keeps the slot. It mints `value(absorbed) × survivor.totalShares / value(survivor)` new shares. The hook stores `absorbed.mergedInto = survivor` and `absorbed.mergeRate = newShares / absorbed.totalShares`.
  4. Holders of the absorbed group are converted the next time they interact. Merges need nothing per user and use no gas per user.
- **Why the older group survives: a share is at most one merge away from its current group.**
  - A strategy never has more than two live groups, one per slot.
  - An emptied group is never reused: the next deposit into its slot gets a new, younger id. A group can't be emptied while absorbed holders still have a claim on it, because their converted shares count in its `totalShares`.
  - The survivor of a merge is the strategy's oldest live group. Any group created later is younger, so the survivor can never be absorbed itself.
  - An absorbed group points straight at a group that is never absorbed, so a withdrawal follows at most one hop. There's no chain to walk, and no way for a griefer to make withdrawals more expensive.
  - An earlier idea, "the larger group survives", doesn't hold up. An attacker could deposit, absorb the honest group, withdraw, and repeat with the same capital, adding one hop each cycle.
- This keeps the gas bound in section 5.2. Without merges, someone could keep making new groups for the same strategy.

## 7. Deposits

1. Check that `key.hooks == this`, the level is on the grid and within tick bounds, and `spreadIndex < K`.
2. If no pool exists for this pair and fee, the hook creates it at the edge of the order: `sqrtPrice(L)` for an ask, `sqrtPrice(L+1)` for a bid. The hook's own call skips `beforeInitialize`, so the hook checks tick spacing 1 and a static fee itself here.
3. If the target level has unflipped crossings, flip it first.
4. **Move the price if needed.** An ask needs `sqrtPrice ≤ sqrtPrice(L)`; a bid needs `sqrtPrice ≥ sqrtPrice(L+1)`. Between the best bid and the best ask there's no liquidity, so the pool price can be anywhere in that gap.
   - When the price is on the wrong side, the hook swaps 1 wei with `sqrtPriceLimit` set to the boundary. With no liquidity in between, the price moves for free.
   - If the price doesn't reach the boundary, orders are in the way, or the level is partly filled. The deposit then reverts (`OrdersInTheWay` / `LevelInRange`).
   - v4 moves the price 256 ticks per step at a few thousand gas per step, so a very long move can exceed one transaction's gas limit (about 16.7M on Ethereum). In that case anyone can first call `movePrice` a few times with intermediate targets. A pool can never be permanently stuck.
5. Compute the liquidity from `amount` (rounded down), collect and credit fees at the level, add the liquidity, and mint shares (`minShares` check). Shares go to the slot's group, or to a new group if the slot is empty.
6. Pay through the PoolManager: ERC-20 `sync`, `transferFrom` and `settle`, or `msg.value` for native ETH. Excess ETH is refunded.

Anyone can move the pool price through empty space at any time. The worst that can do to a deposit is make it revert. It can't change the price an order is placed at.

## 8. Withdrawals

- Follow at most one merge to the group's current slot. Remove `shares × liquidity / totalShares` from the level's position, collecting and crediting fees first, and pay out the proportional share of pending tokens.
- This **always works**: in or out of range, before or after a flip. It touches only that level's position, doesn't depend on the swap budget, and never walks a merge chain. If the price is inside the level, the user receives both tokens.

## 9. Gas and griefing bounds

| Attack | Defense |
|---|---|
| Many deposits at one level | At most 2K slots per level. A flip costs 1 removal and at most K additions, whatever the number of users. |
| Dust orders on the levels nearest the price | Levels tiny compared to the swap are skipped at the cost of one read, so dust can't use up the budget. `settleLevel` flips them. |
| Many real orders crossed at once | `afterSwap` spends at most `maxOpsPerSwap` operations. The rest wait for the next swap or `settle()`, with no loss. |
| v4 tick crossings, which the hook can't cap | Set by `levelSpacing`: at most 1 order level per `levelSpacing` ticks. Each config makes its own trade-off. |
| Pool created at a hostile starting price | Only the hook creates pools, at the first order's own price. |
| Bot stops just before a level's end to dodge its flip | `settleLevel` flips levels that are at least 90% filled. |
| Endless new groups for one strategy | Merges keep at most 2 groups per strategy. |
| Merge chains to make withdrawals expensive | The older group survives, so a share is at most one merge away. |
| Donations to inflate a share price | Donations blocked, plus virtual shares and `minShares`. |
| A destination tick at v4's liquidity limit | The flip keeps the amount as pending tokens. It never reverts. |
| Price pushed far into empty space | Moving it back costs the same as pushing it, and `movePrice` works in chunks, so no pool gets stuck. |
| A swapper sending just enough gas to skip flips | The budget is a fixed count, not based on remaining gas, so a swap does its flips or runs out of gas. |

Remaining risks, accepted for v1:

- **Far first order.** A griefer can create a pool by placing its first order at an absurd price. The pool then starts there, and the next depositor pays once to move the price back. That's negligible on L2s, and a few transactions' worth of gas on mainnet for a very long move.
- **Free option.** While a level is crossed but not yet flipped, the trader who crossed it can reverse at the same price. The budget, skipping and `settleLevel` keep this rare. Users can lose the trade, never funds.

No minimum order size: skipping tiny levels handles dust without one. A minimum set per pool would bring back pool squatting, because the first creator would choose it.

## 10. Known limits

- **Liquidity per tick**: with tick spacing 1, v4 caps each tick at about 1.9e32 liquidity units. Realistic pairs are many orders of magnitude below that. Deposits that would exceed it revert, and flips keep what doesn't fit as pending tokens (section 5.2).
- **Fee-on-transfer and rebasing tokens** aren't supported, as in v4 itself.
- **Fill price**: an order fills inside its one-tick range, within 0.01% of `price(L)`. The arbitrage bot keeps the difference between the market price and the limit price.
- **When orders fill**: an order fills once the market moves past it by enough to cover the bot's gas, including the flip. On mainnet that can mean brief touches of a level don't fill.
- **Rounding dust** from splitting a flip between groups stays in the hook, unowned.
- Solidity 0.8.26 or newer, `cancun` EVM (v4 uses transient storage).

## 11. Repository layout and test plan

```
src/TickTockFactory.sol
src/TickTockHook.sol
src/libraries/LevelBitmap.sol     compressed bitmap with next-level search
src/libraries/OrderMath.sol       one-tick liquidity, amounts, valuing pending tokens
test/                             Foundry tests, v4 deployed locally
script/MineSalt.s.sol             finds a salt for a config
script/Deploy.s.sol               factory, then a config hook
```

Dependencies: `v4-core`, `v4-periphery` (`LiquidityAmounts`), `solady` (`LibClone`), `forge-std`.

Tests:
- Factory: config validation, duplicate refusal, wrong salt refused, address flags, `maxOpsPerSwap < 9` refused.
- Pools:
  - External `initialize`, outside `addLiquidity` and `donate` are all refused.
  - Creation on first deposit, at the order's edge.
  - Tick spacing other than 1 and dynamic fees refused.
- Deposits: ask and bid, price moved through empty space, `OrdersInTheWay`, `LevelInRange`, native ETH, `minShares`, deadline. `movePrice` in several chunks after the price has been pushed far away.
- Flips:
  - One level, exact amounts.
  - A full round trip gives about `1.0001^spread` times the starting token0, minus rounding.
  - Several spreads at one level.
  - A merge between the two sides of a strategy: the older group survives, and shares are correct after it.
  - A destination tick at the liquidity limit: the swap succeeds and the amount ends up pending.
- Budget and skipping:
  - Leftover levels, `settle()`, a stale level un-filling when the price comes back.
  - Dust on every level near the price: real orders behind it still flip in the same swap.
  - Cursors stay correct after deposit nudges and `movePrice`.
- `settleLevel`: a skipped level, a level at 99.99%, and a level below the threshold (refused).
- Fees above 0: fees split fairly between groups that joined at different times.
- Withdrawals: out of range, in range (both tokens), stale level, after a merge. Repeated merge cycles never add a second hop.
- Gas: the worst-case swap with every slot full until the budget runs out. This sets the per-chain value.
- Invariants and fuzzing:
  - The hook's positions plus claims always cover what users can withdraw.
  - No sequence of actions lets a user withdraw more than their share.
  - Withdrawals never revert for a valid position.
  - `afterSwap` never reverts.

## 12. Parameters to tune with the gas tests

| Parameter | Where | Starting value |
|---|---|---|
| `maxOpsPerSwap` | Factory, per chain | Measured; at least 9 |
| `skipDivisor` | Hook constant | `2 × maxOpsPerSwap` |
| `partialFlipThreshold` | Hook constant | 90% |
| Spreads per config | Hook constant | At most 8 |
