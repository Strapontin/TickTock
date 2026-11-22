# TickTock: security notes

Notes for reviewers and auditors. The design is in [DESIGN.md](DESIGN.md); this page covers what the code relies on, how it rounds, and what the tests prove. Nothing here has been externally audited yet.

## Trust model

- **No admin.** No owner, no pause, no upgrades. The factory, the hook implementation and the engine are immutable once deployed. A bug can't be patched, only routed around by deploying new contracts.
- **Uniswap v4 core** (v4.0.0, the deployed release) is trusted: the `PoolManager`'s accounting, its hook-calling rules (`noSelfCall`, address permission bits), and ERC-6909 claims.
- **Tokens** can be anything, including malicious ones. Every hook entry point holds a reentrancy lock (see below), and fee-on-transfer and rebasing tokens aren't supported (DESIGN.md section 10).
- **Keepers** are optional. `flipLevel` and `flipCrossed` are permissionless. If nobody calls them, users can miss trades but never lose funds (DESIGN.md section 5.3).

## Code layout that matters for security

- The factory deploys one implementation (which deploys the engine) and one minimal clone per config. The implementation and the engine both refuse direct calls (`NotAClone`, `NotDelegateCall`).
- The hook runs the engine with `delegatecall`. Both inherit their whole storage layout from `TickTockState`, and neither declares storage of its own. A storage variable added to either derived contract would corrupt state: keep all storage in `TickTockState`.
- Clone config is read from the clone's own code (`LibClone.argsOnClone(address(this))`), so it can't be changed.

## Reentrancy

Every entry point (`deposit`, `withdraw`, `movePrice`, `flipLevel`, `flipCrossed`) and `afterSwap` hold Solady's transient reentrancy lock, forced to transient storage on every chain. The lock is only held inside the hook's own calls, so a refused `afterSwap` can only revert the transaction that called the hook in the first place, never an outside swap. `test/Reentrancy.t.sol` covers:

- A token whose `transferFrom` calls back into each entry point mid-deposit.
- That same token calling `PoolManager.swap` on a TickTock pool mid-deposit. The pool manager is unlocked then, so the swap reaches `afterSwap`, which refuses it.
- An ETH recipient calling back while a withdrawal pays it.

## Rounding

Every rounding goes against the user acting and in favor of the hook and the other holders.

| Where | Rounds | Effect |
|---|---|---|
| Deposit: liquidity from the amount | Down | The depositor buys at most what they pay for. |
| Deposit: payment | Up (v4) | v4's charge for the liquidity, never above `amount`. |
| Deposit: shares | Down, with the group's value rounded up | New shares never dilute existing holders. |
| Withdraw: liquidity and pending share | Down | The last holder of a group gets the remainder. |
| Fee growth and fee credits | Down | Groups are credited at most the fees collected. |
| Flip: each group's part of the removed tokens | Down | Dust stays in the hook as unowned claims. |
| Flip: liquidity re-posted | Down | The unplaced remainder stays in the group's pending tokens. |
| Merge: new shares | Down, with the survivor's value rounded up | The absorbed holders never dilute the survivor's. |
| Converting absorbed shares | Down | At most one share per holder per merge is left unowned. |
| Partial flip threshold (`askSoldBps`, `bidSoldBps`) | Down | A level never flips before it really sold 90%. |

Two facts the flips rely on, both covered by fuzz tests in `test/libraries/OrderMath.t.sol`:

- v4's rounded-up charge for liquidity bought with `amount` never exceeds `amount`. So `total - used` in a placement can't underflow.
- `liquidityForAmount0` divides by the range width first. v4-periphery's ordering loses up to half the value at low prices.

## `unchecked` blocks

| Where | Why it's safe |
|---|---|
| `LevelBitmap.nextUp` / `nextDown` word counters | The loop stops at the last word of the range. |
| `LevelBitmap._decompress` | The compressed index of a valid tick fits in 21 bits, and the result is a valid tick. |
| `TickTockState._modifyLevel` fee growth sums | Wrap on purpose, as v4's fee growth does. Each `mulDiv` can't overflow: fees fit in `int128`. |
| `TickTockState._creditFees` growth differences | Wrap on purpose, like the sums. The additions to pending balances are checked, so a balance can never wrap. |
| `TickTockHook.positionOf` and `_projectedFeeGrowth` | Views. The same wrapping growth math. |

## Narrowing casts

- `uint112` level liquidity: v4 caps a tick at about 2^107 with tick spacing 1, and every level's liquidity sits in one position under that cap.
- `uint128` group liquidity and pending balances: liquidity is under the same cap. Pending balances use checked casts (`toUint128`) and checked arithmetic. Tokens with amounts near 2^127 aren't supported (DESIGN.md section 10).
- Signed to unsigned balance changes: each cast follows the sign v4 guarantees (removals are non-negative, additions non-positive), or an explicit sign check in `_settleDeltas`.
- `mulDiv(shares, x, totalShares)` with `shares <= totalShares` is at most `x`. That covers the withdrawal casts.

## What the invariant suite proves

`test/invariant/` runs random deposits, withdrawals, swaps, flips, partial fills, near-limit fills and price moves on three pools: two share one hook, so they share its claims, and the third starts near tick −600,000, where small amounts reach v4's per-tick limit. After every action it checks:

- Each level's v4 position holds exactly its groups' liquidity, and slots, masks and groups agree.
- Each group's fee snapshot belongs to its current level. A wrong snapshot would let fees be stolen.
- The hook's claims cover every group's pending tokens.
- Absorbed groups point straight at a live, older group (one hop).
- `askCursor <= T <= bidCursor`.
- No swap ever reverts inside `afterSwap`, and no action reverts outside its expected errors.

At the end of each run, every holder withdraws everything: every withdrawal must succeed, and only rounding dust may stay behind. That dust is unowned claims of at most 1e4 wei, and shares nobody owns, at most one per holder per merge.

`test/invariant/HandlerCoverage.t.sol` fails if the handler stops reaching flips, partial flips, merges, skips or capped placements, so the suite can't quietly stop exercising them.

Run it with `forge test` (32 runs of 150 actions) or `FOUNDRY_PROFILE=ci forge test` (128 runs of 250).

## Accepted risks and limits

These are in DESIGN.md sections 9 and 10:

- **The free option** on crossed but unflipped levels: users can lose the trade, never funds.
- **A price pushed far into empty space** makes the next swap toward the orders expensive.
- **v4's per-tick limit** is reachable with high-supply tokens on both sides.
- **Flip gas** is about 300k to 350k per level with one spread, before step 8's optimizations.
