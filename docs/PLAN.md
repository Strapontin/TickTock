# TickTock: build plan

This plan builds the contracts in [DESIGN.md](DESIGN.md) in small steps. Each step builds on the previous one and ends in a working, tested state.

## How each step works

- All work happens on the `feat/v1-contracts` branch, with one or more commits per step. Nothing is pushed until the owner asks.
- A step is done when `forge build` and `forge test` pass, `forge fmt --check` is clean, and DESIGN.md matches what was built.
- Each step ends with a short report: what changed, the test results, and any decision that needs the owner.

## Steps

| # | Step | Status |
|---|---|---|
| 0 | Setup | Done |
| 1 | Libraries | Done |
| 2 | Factory and hook skeleton | Done |
| 3 | Deposits, withdrawals and fees | To do |
| 4 | Flips and merges | To do |
| 5 | Swaps: budget, skipping and cursors | To do |
| 6 | Partial flips | To do |
| 7 | Hardening | To do |
| 8 | Gas and deployment | To do |

### 0. Setup

- Foundry config: solc 0.8.26, `cancun`, via-IR.
- Pinned dependencies: v4-core v4.0.0, solady v0.1.26, forge-std v1.17.0.
- MIT license and a CI workflow that runs format, build and tests.
- Design fixes from the review: the skip rule compares against the largest crossed level, the per-tick limit and unplaced amounts, mint-or-burn settlement, the reentrancy lock, events, the strategy bounds check, renamed functions.

### 1. Libraries

- `LevelBitmap`: set, clear and test a level, plus a search for the next set level up or down within a bounded range.
- `OrderMath`: the one-tick math.
  - Liquidity from an amount, and amounts from liquidity, for `[L, L+1)`.
  - Level sizes for the skip rule.
  - Group values in liquidity units.
  - The fill fraction of a level the price is inside.
  - `T` and the crossing tests from section 5.1.
- Tests:
  - Unit tests, plus fuzzing against a brute-force bitmap.
  - v4's `SqrtPriceMath` as the reference for amounts.
  - A one-tick round-trip check.

### 2. Factory and hook skeleton

- `TickTockFactory`: config validation, duplicate refusal, address-bit check, deterministic clone with args, `predictHookAddress`.
- `TickTockHook`:
  - Config read from the clone's args.
  - The guard that refuses direct calls to the implementation.
  - The transient lock.
  - The refused callbacks: `beforeInitialize`, `beforeAddLiquidity`, `beforeDonate`.
  - `afterSwap` as a stub.
- `script/MineSalt.s.sol` and a test helper that mines salts.
- Tests: the factory list and the pool refusals from DESIGN.md section 11.

### 3. Deposits, withdrawals and fees

- Pool creation on the first deposit.
- Price nudges with the zero-cost check, and `movePrice`.
- Ask and bid deposits, native ETH, shares with virtual offsets, `minShares`, deadlines.
- Per-level fee growth and crediting fees to groups.
- Pending tokens held as ERC-6909 claims, with mint-or-burn settlement.
- Withdrawals in and out of range.
- `afterSwap` still does nothing at this step: swaps fill orders, but nothing flips yet.
- Tests: deposits, withdrawals, fees split between groups that joined at different times, `movePrice` in chunks.

### 4. Flips and merges

- The flip of one level, both sides and several spreads, with compounding.
- The per-tick limit path: place what fits, keep the rest unplaced.
- Merges: the older group survives, `mergedShares`, one-hop conversion on withdrawal.
- `flipLevel` for fully crossed levels.
- Tests:
  - Exact amounts.
  - A round trip gives about `1.0001^spread`.
  - Merges and repeated merge cycles.
  - The tick-limit case.

### 5. Swaps: budget, skipping and cursors

- `afterSwap`: the two-pass scan, the largest-level skip rule, the operation budget and the cursor rules.
- `flipCrossed`.
- Tests:
  - Leftovers.
  - Dust next to real orders.
  - 20 or more equal-size levels in one swap.
  - Stale levels un-filling.
  - Cursors after nudges and `movePrice`.

### 6. Partial flips

- `flipLevel` for levels at least 90% filled; the unsold remainder goes to pending.
- Tests: 99.99% filled, just above and just below the threshold.

### 7. Hardening

- Invariant suite with a handler that runs random deposits, withdrawals, swaps and flips across several pools and configs.
- Reentrancy tests with a malicious token.
- Checks that `afterSwap` and valid withdrawals never revert.
- Review of rounding directions and every `unchecked` block.

### 8. Gas and deployment

- The worst-case swap, measured with every slot full until the budget runs out.
- Gas snapshots.
- Tuning `skipDivisor` and the partial-flip threshold.
- `script/Deploy.s.sol`.
- README usage section.

## After the plan

- **Audit.** An external audit before any mainnet deployment. The contracts have no admin and can't be upgraded, so a bug can't be patched after launch.
- **Out of scope for now:**
  - The front-end.
  - A keeper bot that calls `flipLevel` and `flipCrossed` from events.
  - The far-price mitigation in DESIGN.md section 9.
