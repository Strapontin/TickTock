# TickTock: design spec

Status: approved for implementation. The build plan is in [PLAN.md](PLAN.md).

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
| License | MIT. Every v4-core file the hook compiles in is MIT. |

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
- **Size** of one side of a level: how much of the other token it converts into, up to a constant factor. `askLiquidity × sqrtPrice(L)` for asks (token1), `bidLiquidity / sqrtPrice(L)` for bids (token0). It's only used to compare levels with each other (section 5.3).
- **T**: the tick of the current price, so that `sqrtPrice(T) ≤ price < sqrtPrice(T+1)`. It can be one more than v4's `slot0.tick`, which sits one tick lower when a downward swap stops exactly on a tick boundary.

## 3. Contracts

### 3.1 `TickTockFactory` (one per chain)

- Constructor: `(IPoolManager poolManager, uint16 maxOpsPerSwap)`. It deploys the hook implementation once, with both values as the implementation's immutables, and the implementation deploys the engine (section 3.3). Every clone of this factory shares them.
  - `maxOpsPerSwap` is the most liquidity operations one swap's `afterSwap` may spend. It's chosen per chain from the gas measurements: higher on L2s, lower on mainnet.
  - It must be at least 9 (1 removal plus 8 additions), so that the busiest possible level fits in one swap.
- `createHook(uint24 levelSpacing, int24[] spreads, bytes32 salt) returns (address hook)`:
  - Validates the config (section 2) and refuses it if `configHash = keccak256(abi.encode(levelSpacing, spreads))` already has a hook.
  - Predicts the clone address and requires its low 14 bits to match the hook's permissions exactly (section 3.2). Otherwise it reverts with `InvalidHookAddress`.
  - Deploys a minimal clone of the implementation with immutable args (`levelSpacing`, `spreads`), using Solady `LibClone.cloneDeterministic`. The clone reads them from its own code with `LibClone.argsOnClone`.
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

The hook doesn't inherit v4-periphery's `BaseHook`, whose constructor checks the address bits: the implementation's own address doesn't have them. Instead, the implementation refuses every call that doesn't come through a clone.

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
) external payable returns (uint64 groupId, uint256 shares);

function withdraw(uint64 groupId, uint256 shares, address recipient, uint256 deadline)
    external returns (uint256 amount0, uint256 amount1);

// All permissionless:
function flipCrossed(PoolKey calldata key, uint256 maxOps) external;   // crossed levels the swap budget didn't reach
function flipLevel(PoolKey calldata key, int24 level) external;        // one skipped or mostly-filled level
function movePrice(PoolKey calldata key, uint160 targetSqrtPrice) external; // through empty space only
```

Views: `positionOf(user, groupId)` (current token amounts, fees not yet collected included), `getLevel`, `getGroup`, `getPool` (key and cursors), `slotGroup`, `resolveGroup(groupId)` (follows a merge, see section 6).

**Reentrancy.** Every entry point, `afterSwap` included, takes a lock in transient storage and reverts if it's already held. Pairs can use any token, and the PoolManager stays unlocked during the hook's own calls. Without the lock, a token's `transferFrom` or an ETH recipient could call `swap` on a TickTock pool and run `afterSwap` halfway through a deposit. This doesn't conflict with the rule that `afterSwap` never reverts because of order state (section 5.2): the lock is only held inside the hook's own calls, so the only transaction it can make revert is the one that called the hook.

### 3.3 `TickTockEngine` (one per factory)

The flip logic (sections 5.2 to 5.4) lives in a separate contract, so the hook stays under the 24 KB contract size limit.

- The hook implementation deploys the engine in its constructor and keeps its address as an immutable.
- The hook runs the engine's code with `delegatecall`. The engine then works on the clone's storage, and its pool calls come from the clone, as if the code were the hook's own.
- Both contracts inherit all their storage from one base, `TickTockState`, so their layouts can't drift apart. Neither declares storage of its own.
- The engine refuses direct calls.
- The cost is one `delegatecall`, about 2.6k gas, each time the hook flips. A deposit only calls the engine when its target level is crossed.

### 3.4 Events

| Event | When |
|---|---|
| `HookCreated` (factory) | A config's hook is deployed. |
| `Deposit` | A deposit, with its strategy, group, liquidity and shares. |
| `Withdraw` | A withdrawal, with the amounts paid. |
| `LevelFlipped` | One side of a level flipped, by a swap, `flipCrossed` or `flipLevel`. A flag marks partial flips (section 5.4). |
| `LevelSkipped` | A scan passed over a small level (section 5.3). Bots use it to find levels for `flipLevel`. |
| `GroupsMerged` | Two groups merged: survivor, absorbed group, new shares. |
| `SharesConverted` | A holder's shares in an absorbed group were converted. |
| `AmountUnplaced` | A flip couldn't place an amount because of v4's per-tick limit (section 10). |

Pool creation shows up as v4's own `Initialize` event, which includes the hook address.

## 4. Storage (per pool)

```
Level  { uint112 askLiquidity; uint112 bidLiquidity; uint8 askMask; uint8 bidMask; bool used;   // one word
         uint256 feeGrowth0X128; uint256 feeGrowth1X128; }
Group  { uint128 liquidity; uint128 pending0; uint128 pending1;
         uint256 totalShares; uint256 feeGrowthLast0X128; uint256 feeGrowthLast1X128;
         PoolId poolId; int24 sellLevel; uint8 spreadIndex; bool isBid;   // its current slot
         uint64 mergedInto; uint256 mergedShares; }

levels[poolId][L]                 -> Level
strategyGroups[poolId][S][2k]     -> groupId in the ask slot of strategy (S, k)
strategyGroups[poolId][S][2k+1]   -> groupId in its bid slot   (16 uint64 per sell level, 4 per word)
groups[groupId]                   -> Group    (ids only increase, so a lower id is an older group)
shares[user][groupId]             -> uint256
askBitmap[poolId], bidBitmap[poolId]   levels holding ask or bid slots, compressed by levelSpacing
askCursor[poolId], bidCursor[poolId]   where the next scan starts (section 5.3)
poolKeys[poolId]                  -> PoolKey
```

- The hook owns **one** v4 position per level: `(hook, L, L+1, salt = 0)`. Its liquidity is `askLiquidity + bidLiquidity`.
- `uint112` is enough for a level's liquidity: with tick spacing 1, v4 caps each tick at about 1.9e32 < 2^108, and both sides of a level share one position.
- The masks record which spreads have a group in a slot at that level. That way a flip only visits the slots that exist. A level's bit in a bitmap stays set while that side has a group, even one with zero liquidity (section 10).
- `pending0` and `pending1` are tokens owned by a group but not inside a position: fees, the unsold remainder of a partial flip (section 5.4), and amounts that couldn't be placed (section 10). The hook holds them as ERC-6909 claims on the PoolManager.
- `mergedInto` and `mergedShares` are only set on an absorbed group (section 6). Its `totalShares` is then frozen.
- Group ids are stored by strategy rather than by level, so both slots of a strategy share a storage word. A flip between them rewrites that word instead of clearing one slot and writing a fresh one.
- `used` is set the first time a level holds a group and never cleared. It keeps the level's word non-zero after the level empties, so the next round trip through it writes a used word instead of a fresh one.

## 5. Swaps and flips

### 5.1 When a level counts as crossed

Crossing is decided from `sqrtPrice`, not the tick, which avoids edge cases at range boundaries.

- Asks at `L` are fully converted to token1 when `sqrtPrice ≥ sqrtPrice(L+1)`, that is when `L < T`.
- Bids at `L` are fully converted to token0 when `sqrtPrice ≤ sqrtPrice(L)`, that is when `L > T`, or `L == T` with the price exactly on `sqrtPrice(T)`.

If the price stops inside `[L, L+1)`, the level is partly filled and `afterSwap` doesn't flip it. `flipLevel` can flip it once it's mostly filled (section 5.4).

### 5.2 Flipping a level (asks at `L`, price moved up; bids work the same way in reverse)

1. Remove `askLiquidity` from the level's position. The result is the principal in token1 plus fees in both tokens. The fees go into the level's fee growth, using the liquidity the level had before the removal.
2. For each spread `k` in `askMask`, for its group `g`:
   - Credit `g` its fees from the level's fee growth into `pending0` and `pending1`.
   - `g` gets `principal1 × g.liquidity / askLiquidity`, plus `g.pending1` (compounding).
3. For each `k`, add the token1 amount as liquidity at `B = L - spreads[k]`, one liquidity operation per destination level.
   - Any fees collected while touching `B` first go into `B`'s fee growth, credited to the slots already there.
   - Before adding, check the destination ticks against v4's per-tick liquidity limit. The flip places what fits and keeps the rest in `g`'s pending tokens (section 10).
4. Place `g` in slot `bid(L, k)` at `B`:
   - If that slot is empty, `g` just moves there. Its shares don't change.
   - Otherwise the two groups **merge** (section 6).
5. Update masks, totals, bitmaps and cursors.
6. Settle the hook's own balance changes once, at the end of the call. The removal and the additions are in the same token and nearly cancel out. For each token, a positive remainder (fees, rounding dust, amounts that didn't fit) is minted to the hook as ERC-6909 claims. A negative one (pending tokens compounded into the additions) is paid by burning claims. No tokens move.

Cost per crossed level: 1 removal, at most K additions (K = number of spreads in the menu), and up to 2K group updates. **This does not depend on how many users or deposits are at that level.**

No chain reactions: the price only moves one way during a swap, and re-posted orders always land behind it, so the same swap can't fill them.

**Rule: `afterSwap` never reverts because of order state.** If it could, a griefer could set up orders so that every swap through a level reverts. Anything that can't be done right away is left for later (pending tokens, an unflipped level) instead.

### 5.3 Budget, skipping and cursors

- **Budget.** `afterSwap` spends at most `maxOpsPerSwap` liquidity operations. It goes through the crossed levels in price order, starting at the cursor. A level is flipped completely or not at all. A level costs one removal (if that side has liquidity) plus one addition per spread in its mask.
- **Skipping small levels.** A crossed level that is small compared to the **largest level crossed in the same scan** is skipped: it costs one storage read instead of a flip.
  - "Small" means `size × skipDivisor < largest size`. `skipDivisor` starts at `2 × maxOpsPerSwap` and will be tuned with the gas tests.
  - The scan makes two passes over the crossed levels. The first only reads them to find the largest size; the second flips or skips them. A read costs far less than the tick crossings v4 already charged the swapper for the same levels.
  - Dust can't use up the budget, because it's small next to the real orders crossed with it.
  - Levels of similar size are never skipped, however many a swap crosses. The budget flips the first ones and the rest are ordinary leftovers.
  - To get a real order skipped, an attacker needs an order `skipDivisor` times bigger in the same scan: real capital, in an order that actually trades.
  - Skipped levels can be flipped by anyone with `flipLevel`. The `LevelSkipped` event says which ones.
- **Leftovers.** Levels the budget didn't reach stay crossed but unflipped. They're picked up by the next swap in the same direction, or by anyone calling `flipCrossed`, which runs the same scan on both sides with a budget the caller picks and returns the operations it spent.
- **Swaps that cross nothing.** `afterSwap` first checks the bitmap between the cursor and the last crossed level. If no level there holds orders, it only updates the cursors, without calling the engine.
- **No loss from a late flip.** A level that wasn't flipped is still a normal position. If the price comes back, it simply un-fills (it buys back at the same price). The user misses a trade but loses nothing.
- **Cursors.** An upward scan covers the ask levels in `[askCursor, T-1]`. A downward scan covers the bid levels from `bidCursor` down to the lowest crossed one. With `T` taken after the price move:
  - On pool creation, both cursors are set to `T`.
  - After an upward scan, `askCursor` is the first level the budget didn't reach, or `T` if there is none. Skipped levels are passed over. Then `bidCursor = max(bidCursor, T)`.
  - After a downward scan, `bidCursor` is the first level the budget didn't reach, or `T`. Then `askCursor = min(askCursor, T)`.
  - The hook's own price moves (deposit nudges, `movePrice`) cross no orders, so they only do the second half: after moving down, `askCursor = min(askCursor, T)`; after moving up, `bidCursor = max(bidCursor, T)`. They skip `afterSwap`, so this is done in the hook's own code.
  - This keeps `askCursor ≤ T ≤ bidCursor` at all times, so every new order lands inside the range its side's next scan will cover.
- The scan reads one bitmap word per 256 levels. That is no more than the PoolManager already read to move the price that far, so a swapper's cost grows with the distance they moved the price.

### 5.4 `flipLevel` and mostly-filled levels

A bot can stop its swap just before the end of the last level, filling 99.99% of it, so it never pays for that level's flip. Without a fix, the level stays unflipped. If the price comes back, the order un-fills: the bot got a free option, and the user misses the round trip.

`flipLevel(key, L)` handles this. Anyone can call it, typically the order's owner or a bot run by the front-end.

- If the level is fully crossed (a skipped level, or one the budget didn't reach), it flips as in section 5.2.
- If the price is inside the level, it flips once at least `partialFlipThreshold` of the level's starting token has been sold. That threshold starts at 90% and will be tuned in tests.
  - The unsold remainder goes to each group's pending tokens and is re-posted when the group comes back to that side.
- A bot that stops before the threshold to dodge this gives up the rest of that level's trade. That's only worth it on tiny levels.
- Only `flipLevel` flips a partly filled level. Swaps never do, and a deposit into one reverts with `LevelInRange`.

## 6. Shares and merges

- **Value.** A group's value is counted in liquidity units of the level it sits in: its liquidity, plus its pending tokens converted to liquidity over that level's range (`pending0` as if it were an ask there, `pending1` as if it were a bid). Both conversions use the level's own fill price from tick math, not the pool's live price, so they can't be manipulated.
- **Shares.** Inside a slot, liquidity is a fair measure of value: same range, same token. A deposit of `ΔL` mints `ΔL × (totalShares + 1) / (value + 1)` shares, rounded down, with `value` rounded up.
  - The `+ 1` terms are virtual shares. Together with rounding in favor of existing holders, they protect against the share-inflation attack. Blocking donations removes the main way to inflate a group's value for free.
- **When merges happen.** Alice asks at 1000 with spread k, and Bob bids at 900 with the same spread. That's the same strategy on opposite sides, so they're two groups. When Alice's group flips to 900, Bob's group is already in that slot, and the two merge.
- **How a merge works.**
  1. The waiting group's pending tokens in the slot's own token are compounded into the same liquidity operation.
  2. Each group is valued as above.
  3. **The older group (lower id) survives** and keeps the slot. It mints `newShares = value(absorbed) × (survivor.totalShares + 1) / (value(survivor) + 1)` into its own `totalShares`. The hook stores `absorbed.mergedInto = survivor` and `absorbed.mergedShares = newShares`, and freezes `absorbed.totalShares`.
  4. Holders of the absorbed group are converted the next time they interact, at `userShares × mergedShares / totalShares`, rounded down. Merges need nothing per user and use no gas per user. The rate is stored as two integers rather than a fixed-point number, so it's exact whatever the two groups' share prices. With a very wide spread they can differ by many orders of magnitude.
- **Why the older group survives: a share is at most one merge away from its current group.**
  - A strategy never has more than two live groups, one per slot.
  - An emptied group is never reused: the next deposit into its slot gets a new, younger id. A group can't be emptied while absorbed holders still have a claim on it, because their converted shares count in its `totalShares`.
  - The survivor of a merge is the strategy's oldest live group. Any group created later is younger, so the survivor can never be absorbed itself.
  - An absorbed group points straight at a group that is never absorbed, so a withdrawal follows at most one hop. There's no chain to walk, and no way for a griefer to make withdrawals more expensive.
  - An earlier idea, "the larger group survives", doesn't hold up. An attacker could deposit, absorb the honest group, withdraw, and repeat with the same capital, adding one hop each cycle.
- This keeps the gas bound in section 5.2. Without merges, someone could keep making new groups for the same strategy.

## 7. Deposits

1. Check that `key.hooks == this`, `spreadIndex < K`, and that both levels of the strategy, `S` and `S - spreads[k]`, are on the grid and inside v4's tick bounds (`S - spreads[k] ≥ MIN_TICK` and `S + 1 ≤ MAX_TICK`).
2. If no pool exists for this pair and fee, the hook creates it at the edge of the order: `sqrtPrice(L)` for an ask, `sqrtPrice(L+1)` for a bid. The hook's own call skips `beforeInitialize`, so the hook checks tick spacing 1 and a static fee itself here.
3. If the target level has unflipped crossings, flip it first.
4. **Move the price if needed.** An ask needs `sqrtPrice ≤ sqrtPrice(L)`; a bid needs `sqrtPrice ≥ sqrtPrice(L+1)`. Between the best bid and the best ask there's no liquidity, so the pool price can be anywhere in that gap.
   - When the price is on the wrong side, the hook swaps 1 wei with `sqrtPriceLimit` set to the boundary. With no liquidity in between, the price moves for free.
   - The deposit requires that swap to reach the boundary and to cost nothing. Otherwise orders are in the way, or the level is partly filled, and the deposit reverts (`OrdersInTheWay` / `LevelInRange`). Checking the cost matters: 1 wei can be enough to push through a dust order, which would trade it without a flip.
   - v4 moves the price 256 ticks per step at a few thousand gas per step, so a very long move can exceed one transaction's gas limit (about 16.7M on Ethereum). In that case anyone can first call `movePrice` a few times with intermediate targets. A pool can never be permanently stuck.
5. Compute the liquidity from `amount` (rounded down), collect and credit fees at the level, add the liquidity, and mint shares (`minShares` check). Shares go to the slot's group, or to a new group if the slot is empty.
6. Pay through the PoolManager: ERC-20 `sync`, `transferFrom` and `settle`, or `msg.value` for native ETH. The depositor pays exactly what v4 asks for the added liquidity, at most `amount`. Excess ETH is refunded.

Anyone can move the pool price through empty space at any time. The worst that can do to a deposit is make it revert. It can't change the price an order is placed at.

## 8. Withdrawals

- If `groupId` was absorbed, the caller's whole balance in it is converted first (one hop, section 6). `shares` is counted in the units of the group id passed in.
- Remove `shares × liquidity / totalShares` from the level's position, collecting and crediting fees first, and pay out the proportional share of pending tokens.
- This **always works**: in or out of range, before or after a flip. It touches only that level's position, doesn't depend on the swap budget, and never walks a merge chain. If the price is inside the level, the user receives both tokens.

## 9. Gas and griefing bounds

| Attack | Defense |
|---|---|
| Many deposits at one level | At most 2K slots per level. A flip costs 1 removal and at most K additions, whatever the number of users. |
| Dust orders on the levels nearest the price | Levels small next to the largest level crossed with them are skipped at the cost of one read, so dust can't use up the budget. `flipLevel` flips them. |
| Many real orders crossed at once | `afterSwap` spends at most `maxOpsPerSwap` operations. Levels of similar size are never skipped; the rest wait for the next swap or `flipCrossed`, with no loss. |
| v4 tick crossings, which the hook can't cap | Set by `levelSpacing`: at most 1 order level per `levelSpacing` ticks. Each config makes its own trade-off. |
| Pool created at a hostile starting price | Only the hook creates pools, at the first order's own price. |
| Bot stops just before a level's end to dodge its flip | `flipLevel` flips levels that are at least 90% filled. |
| Endless new groups for one strategy | Merges keep at most 2 groups per strategy. |
| Merge chains to make withdrawals expensive | The older group survives, so a share is at most one merge away. |
| Donations to inflate a share price | Donations blocked, plus virtual shares and `minShares`. |
| A destination tick at v4's liquidity limit | The flip places what fits and keeps the rest as pending tokens. It never reverts. |
| A token callback re-entering the hook mid-deposit | A transient lock on every entry point, `afterSwap` included. |
| Price pushed far into empty space | Anyone can move it back with `movePrice`, in chunks, so no pool gets stuck. Until someone does, the next swap toward the orders pays for the walk (see below). |
| A swapper sending just enough gas to skip flips | The budget is a fixed count, not based on remaining gas, so a swap does its flips or runs out of gas. |

Remaining risks, accepted for v1:

- **Far first order.** A griefer can create a pool by placing its first order at an absurd price. The pool then starts there, and the next depositor pays once to move the price back. That's negligible on L2s, and a few transactions' worth of gas on mainnet for a very long move.
- **Price pushed into empty space.** When orders sit on one side only, anyone can push the price to the far end of the empty range with a free 1-wei swap. The next swap toward the orders then pays to walk it back, which can cost millions of gas, so routers will avoid the pool until someone calls `movePrice`. The pusher pays about as much as the fix. A later version could have `afterSwap` move the price back near the nearest order, so the pusher pays both ways.
- **Free option.** While a level is crossed but not yet flipped, the trader who crossed it can reverse at the same price. The budget, skipping and `flipLevel` keep this rare. Users can lose the trade, never funds.

No minimum order size: skipping small levels handles dust without one. A minimum set per pool would bring back pool squatting, because the first creator would choose it.

## 10. Known limits

- **Liquidity per tick**: with tick spacing 1, v4 caps each tick at about 1.9e32 liquidity units, and neighbouring levels share a tick when `levelSpacing` is 1.
  - For a one-tick range, liquidity ≈ 20,000 × amount0 × √price, in raw token units. The cap is out of reach for most pairs, but not all. When both tokens have tiny unit values, such as two high-supply 18-decimal tokens at about $0.00001 each, a single level hits it at roughly $100k.
  - Deposits that would exceed it revert. A flip places what fits and keeps the rest as pending tokens (`AmountUnplaced`).
  - An unplaced amount is never treated as traded. It stays in its token, rides along when the group flips, and is placed again the next time the group's tokens are re-posted in that token: its next flip to that side, or a merge into its slot. Withdrawals always pay it out. A group whose whole amount is unplaced keeps its slot with zero liquidity.
- **Token amounts**: pending tokens are `uint128`, and v4's own deltas are `int128`. Tokens whose amounts can get near 2^127 raw units aren't supported.
- **Fee-on-transfer and rebasing tokens** aren't supported, as in v4 itself.
- **Fill price**: an order fills inside its one-tick range, within 0.01% of `price(L)`. The arbitrage bot keeps the difference between the market price and the limit price.
- **When orders fill**: an order fills once the market moves past it by enough to cover the bot's gas, including the flip. On mainnet that can mean brief touches of a level don't fill.
- **Rounding dust** from splitting a flip between groups stays in the hook, unowned.
- **v4 protocol fee**: Uniswap governance can switch on v4's protocol fee for any pool. It would come out of the LP fees TickTock users earn. Nothing else changes.
- Solidity 0.8.26 exactly (v4-core's `PoolManager` pins it), `cancun` EVM (v4 uses transient storage), 200 optimizer runs so the hook fits the 24 KB contract size limit.

## 11. Repository layout and test plan

```
src/TickTockFactory.sol
src/TickTockHook.sol
src/TickTockEngine.sol            flip logic, run by the hook with delegatecall
src/base/TickTockState.sol        storage, types, events and errors shared by the hook and the engine
src/libraries/HookConfig.sol      config validation and its encoding as clone args
src/libraries/LevelBitmap.sol     compressed bitmap with next-level search
src/libraries/OrderMath.sol       one-tick liquidity and amounts, sizes, values, fill fractions
test/                             Foundry tests, v4 deployed locally
script/HookSaltMiner.sol          salt search, shared by the script and the tests
script/MineSalt.s.sol             finds a salt for a config
script/Deploy.s.sol               factory, then a config hook
```

Dependencies, pinned: `v4-core` v4.0.0 (the deployed release), `solady` v0.1.26 (`LibClone`), `forge-std` v1.17.0. `v4-periphery` isn't needed: the one-tick liquidity math is a few lines on top of v4-core's `SqrtPriceMath` and `FullMath`. If the hook outgrows the 24 KB contract size limit again, the views move to a separate lens contract.

Tests:
- Factory: config validation, duplicate refusal, wrong salt refused, address flags, `maxOpsPerSwap < 9` refused, the implementation refusing direct calls.
- Pools:
  - External `initialize`, outside `addLiquidity` and `donate` are all refused.
  - Creation on first deposit, at the order's edge.
  - Tick spacing other than 1 and dynamic fees refused.
- Deposits: ask and bid, price moved through empty space, `OrdersInTheWay`, `LevelInRange`, a nudge that would trade a dust order refused, native ETH, `minShares`, deadline. `movePrice` in several chunks after the price has been pushed far away.
- Flips:
  - One level, exact amounts.
  - A full round trip gives about `1.0001^spread` times the starting token0, minus rounding.
  - Several spreads at one level.
  - A merge between the two sides of a strategy: the older group survives, and shares are correct after it.
  - A destination tick at the liquidity limit: the swap succeeds, the amount ends up pending, and it's placed at the group's next flip to that side.
- Budget and skipping:
  - Leftover levels, `flipCrossed`, a stale level un-filling when the price comes back.
  - Dust next to real orders: the dust is skipped and the real orders flip in the same swap.
  - 20 or more levels of equal size crossed at once: none is skipped, the budget flips the first ones, and `flipCrossed` flips the rest.
  - Cursors stay correct after deposit nudges and `movePrice`.
- `flipLevel`: a skipped level, a level at 99.99%, and a level below the threshold (refused).
- Fees above 0: fees split fairly between groups that joined at different times.
- Withdrawals: out of range, in range (both tokens), stale level, after a merge. Repeated merge cycles never add a second hop.
- Reentrancy: a token whose `transferFrom` swaps on a TickTock pool can't re-enter the hook.
- Gas: the worst-case swap with every slot full until the budget runs out. This sets the per-chain value.
- Invariants and fuzzing:
  - The hook's positions plus claims always cover what users can withdraw.
  - No sequence of actions lets a user withdraw more than their share.
  - Withdrawals never revert for a valid position.
  - `afterSwap` never reverts.

## 12. Parameters

| Parameter | Where | Value |
|---|---|---|
| `maxOpsPerSwap` | Factory, per chain | 9 on Ethereum mainnet, 24 on L2s (see below) |
| `skipDivisor` | Hook | `2 × maxOpsPerSwap`, compared against the largest crossed level |
| `PARTIAL_FLIP_THRESHOLD_BPS` | Hook constant | 9000 (90%) |
| Spreads per config | `HookConfig` | At most 8 |

`test/Gas.t.sol` measures the costs and records them in `snapshots/TickTock.json`. The test PoolManager is compiled with 200 optimizer runs instead of the deployed 44,444,444, so v4's share is slightly overstated.

- A swap that crosses no level costs about 68k gas; one that stops inside a level, about 165k.
- Each liquidity operation of a flip costs up to about 230k gas when its destination is a fresh level: v4 initializes the destination's two ticks and its position, about 170k of that. Destinations already holding liquidity cost far less: a level with 8 spreads merging into 8 waiting groups takes about 700k for 9 operations, against 2.2M into fresh levels.
- So the worst case added to a swap is about `230k × maxOpsPerSwap`: about 2.1M gas at 9 and 5.5M at 24.

9 is the floor (the busiest level must fit in one swap) and keeps the worst case near 2M gas on mainnet. On L2s, gas is cheap and transaction limits are higher, so 24 flips more crossed levels per swap and leaves fewer for keepers. Use the gas test's numbers to pick a different value for a specific chain.

`skipDivisor` and the partial-flip threshold kept their starting values: the gas tests gave no reason to move them. Both are judgment calls about griefing rather than gas, and deployment data could justify tuning them in a later version.
