# TickTock: design spec

Status: draft for review. Nothing is implemented yet.

TickTock is a Uniswap v4 hook for double-sided limit orders. A user deposits one token and picks two prices. The hook sells at the high price, buys back at the low price, and repeats this forever, compounding everything. The hook is the only liquidity provider in its pools. Routers and arbitrage bots fill the orders.

## 1. Decisions

| Topic | Decision |
|---|---|
| Liquidity in TickTock pools | Only the hook's. `beforeAddLiquidity` reverts for everyone else. |
| Pairs and chains | Any pair, including native ETH, on any chain where v4 runs. |
| Pool fee | Any static fee, chosen by whoever creates the pool. Dynamic fees are rejected. |
| Tick spacing | Always 1. Each order is a one-tick range. |
| Strategy | A sell price plus a spread picked from a fixed menu. It repeats until the user withdraws. |
| Profit | Compounded. Each flip re-posts everything, LP fees included. |
| Starting token | Either one: token0 starts with the sell, token1 starts with the buy. |
| Configs | A factory deploys one hook per config (spread menu plus level spacing). Anyone can deploy a config; duplicates are refused. |
| Pools | Anyone can create a pool for any pair and fee under any config hook. A pool's starting price doesn't matter. |
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

## 3. Contracts

### 3.1 `TickTockFactory` (one per chain)

- Constructor: `(IPoolManager poolManager, uint16 maxLevelsPerSwap)`. It deploys the hook implementation once.
  - `maxLevelsPerSwap` is chosen per chain from the gas measurements: higher on L2s, lower on mainnet.
- `createHook(uint24 levelSpacing, int24[] spreads, bytes32 salt) returns (address hook)`:
  - Validates the config (section 2) and refuses it if `configHash = keccak256(levelSpacing, spreads)` already has a hook.
  - Predicts the clone address and requires its low 14 bits to match the hook's permissions exactly (section 3.2). Otherwise it reverts with `InvalidHookAddress`.
  - Deploys a minimal clone of the implementation with immutable args (`poolManager`, `maxLevelsPerSwap`, `levelSpacing`, `spreads`), using Solady `LibClone.cloneDeterministic`.
  - Emits `HookCreated(configHash, hook, levelSpacing, spreads)`.
- Views:
  - `hookOf(configHash)`.
  - `predictHookAddress(levelSpacing, spreads, salt)`, used by the salt-mining script. A valid salt takes on average 16,384 tries off-chain, a few seconds.
- If someone front-runs a `createHook` with the same salt and config, they deploy the same hook at the same address, so it does no harm.

Clones cost about 100k gas to deploy instead of several million for a full contract. In exchange, each hook call pays a small `delegatecall` overhead, roughly 3k gas per swap.

### 3.2 `TickTockHook` (one per config)

Permissions, which must match the address bits exactly:

| Flag | Why |
|---|---|
| `beforeInitialize` | Require `tickSpacing == 1` and a static fee. |
| `beforeAddLiquidity` | Always revert. The hook's own calls never reach it (v4 `noSelfCall`), so only outside LPs are blocked. |
| `afterSwap` | Flip the crossed levels. |

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

function settle(PoolKey calldata key, uint256 maxLevels) external; // permissionless
```

Views: `positionOf(user, groupId)` (current token amounts), `getLevel`, `getGroup`, `resolveGroup(groupId)` (follows merges, see section 6).

## 4. Storage (per pool)

```
Level  { uint128 askLiquidity; uint128 bidLiquidity; uint8 askMask; uint8 bidMask;
         uint256 feeGrowth0X128; uint256 feeGrowth1X128; }
Group  { uint128 liquidity; uint128 totalShares; uint128 pending0; uint128 pending1;
         uint256 feeGrowthLast0X128; uint256 feeGrowthLast1X128;
         uint64 mergedInto; uint192 mergeRateX96; slot location }

levels[poolId][L]            -> Level
slotGroup[poolId][slotKey]   -> groupId
groups[groupId]              -> Group
shares[user][groupId]        -> uint256
askBitmap[poolId], bidBitmap[poolId]   levels holding asks or bids, compressed by levelSpacing
askCursor[poolId], bidCursor[poolId]   where the next scan starts (section 5.3)
```

- The hook owns **one** v4 position per level: `(hook, L, L+1, salt = 0)`. Its liquidity is `askLiquidity + bidLiquidity`.
- The masks record which spreads have a non-empty slot at that level. That way a flip only visits the slots that exist.
- `pending0` and `pending1` are tokens owned by a group but not inside a position: fees, and fees in the token the group doesn't currently hold. The hook holds them as ERC-6909 claims on the PoolManager.

## 5. Swaps and flips

### 5.1 When a level counts as crossed

Crossing is decided from `sqrtPrice`, not the tick, which avoids edge cases at range boundaries.

- Asks at `L` are fully converted to token1 when `sqrtPrice ≥ sqrtPrice(L+1)`.
- Bids at `L` are fully converted to token0 when `sqrtPrice ≤ sqrtPrice(L)`.

If the price stops inside `[L, L+1)`, the level is partly filled and nothing flips.

### 5.2 Flipping a level (asks at `L`, price moved up; bids work the same way in reverse)

1. Remove `askLiquidity` from the level's position. The result is the principal in token1 plus fees in both tokens. The fees go into the level's fee growth, using the liquidity the level had before the removal.
2. For each spread `k` in `askMask`, for its group `g`:
   - Credit `g` its fees from the level's fee growth into `pending0` and `pending1`.
   - `g` gets `principal1 × g.liquidity / askLiquidity`, plus `g.pending1` (compounding).
3. For each `k`, add the token1 amount as liquidity at `B = L - spreads[k]`, one `modifyLiquidity` call per destination level.
   - Any fees collected while touching `B` first go into `B`'s fee growth, credited to the slots already there.
4. Place `g` in slot `bid(L, k)` at `B`:
   - If that slot is empty, `g` just moves there. Its shares don't change.
   - Otherwise `g` **merges** into the group already there (section 6).
5. Update masks, totals, bitmaps and `bidCursor`.
6. Settle the hook's own balance changes. The removal and the additions are in the same token and nearly cancel out. What's left (fees, rounding dust) is minted to the hook as ERC-6909 claims. No tokens move.

Cost per crossed level: 1 removal, at most K additions (K = number of spreads in the menu), and up to 2K group updates. **This does not depend on how many users or deposits are at that level.**

No chain reactions: the price only moves one way during a swap, and re-posted orders always land behind it, so the same swap can't fill them.

### 5.3 Cap per swap and `settle()`

- `afterSwap` handles at most `maxLevelsPerSwap` levels, starting from the one nearest the price where the swap began.
- Levels left over stay crossed but unflipped. They're picked up by the next swap in the same direction, or by anyone calling `settle()`.
- A level that wasn't flipped is still a normal position. If the price comes back, it simply un-fills (it buys back at the same price). The user misses a trade but loses nothing.
- Cursors:
  - `askCursor` is at or below every ask level that might need flipping.
  - Upward swaps scan `askBitmap` from `askCursor` up to the current price, then move the cursor to the first unflipped level, or to the current price if none are left.
  - Deposits and flips that create an ask at `L` set `askCursor = min(askCursor, L)`. `bidCursor` works the same way in the other direction.
- The scan reads one bitmap word per 256 levels. That is no more than the PoolManager already read to move the price that far, so a swapper's cost grows with the distance they moved the price.

## 6. Shares and merges

- Inside a slot, liquidity is a fair measure of value: same range, same token. A deposit of `ΔL` mints `ΔL × totalShares / value` shares.
  - `value` is the group's liquidity plus its pending tokens converted to liquidity at the level's price, which is known to within one tick.
  - Virtual shares and rounding in favor of existing holders protect against the share-inflation attack.
- **Merges.** Alice asks at 1000 with spread k, and Bob bids at 900 with the same spread. That's the same strategy on opposite sides, so they're two groups. When Alice's group flips to 900, Bob's group is already in that slot:
  - First the waiting group's pending tokens in the slot's own token are compounded into the same `modifyLiquidity` call.
  - Each group is valued as liquidity plus its other pending tokens, converted at the level's price.
  - The arriving group `g` is absorbed: the waiting group `h` mints `value(g) × h.totalShares / value(h)` new shares. The hook stores `g.mergedInto = h` and `g.mergeRate = newShares / g.totalShares`.
  - Holders of `g` are converted the next time they interact (`withdraw` and `resolveGroup` follow the chain and compress it). Merges need nothing per user and use no gas per user.
- So a strategy has at most two groups (one per side), and each slot has at most one. This keeps the gas bound in section 5.2. Without merges, someone could keep making new groups for the same strategy.

## 7. Deposits

1. Check that `key.hooks == this`, the level is on the grid and within tick bounds, and `spreadIndex < K`.
2. If the pool doesn't exist, the hook initializes it with a price just on the correct side of the order. Because v4 skips hook calls made by the hook itself, the hook checks the tick spacing and fee itself here.
3. If the target level has unflipped crossings, flip it first.
4. **Move the price if needed.** An ask needs `sqrtPrice ≤ sqrtPrice(L)`; a bid needs `sqrtPrice ≥ sqrtPrice(L+1)`. Between the best bid and the best ask there's no liquidity, so the pool price can be anywhere in that gap.
   - When the price is on the wrong side, the hook swaps 1 wei with `sqrtPriceLimit` set to the boundary. With no liquidity in between, the price moves for free.
   - If the price doesn't reach the boundary, orders are in the way, or the level is partly filled. The deposit then reverts (`OrdersInTheWay` / `LevelInRange`).
5. Compute the liquidity from `amount` (rounded down), collect and credit fees at the level, add the liquidity, and mint shares (`minShares` check). Shares go to the slot's group, or to a new group if the slot is empty.
6. Pay through the PoolManager: ERC-20 `sync`, `transferFrom` and `settle`, or `msg.value` for native ETH. Excess ETH is refunded.

Anyone can move the pool price through empty space at any time. The worst that can do to a deposit is make it revert. It can't change the price an order is placed at.

## 8. Withdrawals

- Follow merges to the group's current slot. Remove `shares × liquidity / totalShares` from the level's position, collecting and crediting fees first, and pay out the proportional share of pending tokens.
- This **always works**: in or out of range, before or after a flip. It touches only that level's position and doesn't depend on the swap cap. If the price is inside the level, the user receives both tokens.

## 9. Gas and griefing bounds

| Attack | Bound |
|---|---|
| Many deposits at one level | At most 2K slots per level. A flip costs 1 removal and at most K additions, whatever the number of users. |
| Dust orders on many levels | `afterSwap` handles at most `maxLevelsPerSwap` levels. The rest wait for the next swap or `settle()`, with no loss. |
| v4 tick crossings, which the hook can't cap | Set by `levelSpacing`: at most 1 order level per `levelSpacing` ticks. Each config makes its own trade-off. |
| Endless new groups for one strategy | Merges keep at most 2 groups per strategy (section 6). |
| Moving the price through empty space | Free, but the mover pays for the scan, and deposits revert rather than land at a worse price. |

No minimum order size: the bounds above hold without one. A minimum can be added later if tests show a need.

## 10. Known limits

- **Liquidity per tick**: with tick spacing 1, v4 caps each tick at about 1.9e32 liquidity units. Realistic pairs are many orders of magnitude below that. Deposits that would exceed it revert.
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
- Factory: config validation, duplicate refusal, wrong salt refused, address flags.
- Pools: tick spacing other than 1 refused, dynamic fee refused, outside `addLiquidity` refused, auto-initialization on first deposit.
- Deposits: ask and bid, price moved through empty space, `OrdersInTheWay`, `LevelInRange`, native ETH, `minShares`, deadline.
- Flips:
  - One level, exact amounts.
  - A full round trip gives about `1.0001^spread` times the starting token0, minus rounding.
  - Several spreads at one level.
  - A merge between the two sides of a strategy, and shares after it.
- Cap: leftover levels, `settle()`, a stale level un-filling when the price comes back.
- Fees above 0: fees split fairly between groups that joined at different times.
- Withdrawals: out of range, in range (both tokens), stale level, after one or more merges.
- Gas: worst-case swap with every slot full on `maxLevelsPerSwap` levels. This sets the per-chain value.
- Invariants and fuzzing:
  - The hook's positions plus claims always cover what users can withdraw.
  - No sequence of actions lets a user withdraw more than their share.
  - Withdrawals never revert for a valid position.

## 12. Assumptions to confirm

These were not discussed explicitly. Each is easy to change.

1. At most 8 spreads per config.
2. Pending tokens of the "wrong" side are valued at the level's price when merging or minting shares.
3. The hook auto-initializes pools on first deposit, and anyone can also initialize a pool directly.
4. `maxLevelsPerSwap` is fixed per chain in the factory, not per config.
5. No minimum order size.
