# TickTock: build plan

This plan builds the contracts in [DESIGN.md](DESIGN.md) in small steps, then takes them to a testnet. Each step builds on the previous one and ends in a working, tested state.

- **Phase 1, steps 0 to 8: the contracts.** Done, built on the `feat/v1-contracts` branch.
- **Phase 2, steps 9 to 15: testnet and the off-chain services.** Unichain Sepolia first, then an audit.

## How each step works

- A step is done when `forge build` and `forge test` pass, `forge fmt --check` is clean, and DESIGN.md matches what was built. Off-chain steps also need their own tests and type checks to pass.
- Each step ends with a short report: what changed, the test results, and any decision that needs the owner.
- Phase 1 worked on `feat/v1-contracts` and pushed nothing. From phase 2 on:
  - The contracts, scripts and docs live on `main`, and `main` is pushed when a step is done.
  - The indexer and keeper live on the `offchain` branch. It starts from `main` and merges `main` to pick up contract changes, so it always builds the ABIs from the current contracts.
  - The front end will get a branch of its own later.

## Phase 1: the contracts

| # | Step | Status |
|---|---|---|
| 0 | Setup | Done |
| 1 | Libraries | Done |
| 2 | Factory and hook skeleton | Done |
| 3 | Deposits, withdrawals and fees | Done |
| 4 | Flips and merges | Done |
| 5 | Swaps: budget, skipping and cursors | Done |
| 6 | Partial flips | Done |
| 7 | Hardening | Done |
| 8 | Gas and deployment | Done |

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

- Code size: the flip code didn't fit in the hook, so it lives in `TickTockEngine`, run with `delegatecall` on the hook's storage (DESIGN.md section 3.3). After this step the hook is 18.8 KB and the engine 7.3 KB.
- The flip of one level, both sides and several spreads, with compounding.
- The per-tick limit path: place what fits, keep the rest unplaced.
- Merges: the older group survives, `mergedShares`, one-hop conversion on withdrawal.
- `flipLevel` for fully crossed levels.
- Deposits flip their target level first when it's crossed (DESIGN.md section 7, step 3). Until then, such a deposit reverts with `OrdersInTheWay`.
- Tests:
  - Exact amounts.
  - A round trip gives about `1.0001^spread`.
  - Merges and repeated merge cycles.
  - The tick-limit case.

### 5. Swaps: budget, skipping and cursors

- `afterSwap`: the two-pass scan, the largest-level skip rule, the operation budget and the cursor rules. The scan goes in the engine.
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

- Gas tests for every main operation, recorded in `snapshots/TickTock.json`, including the worst case: the budget spent on 8-spread levels flipping into fresh destinations.
- Five storage optimizations, saving 4% to 21% depending on the operation (14% on the worst case):
  - Both slots of a strategy share one storage word.
  - Each level keeps a `used` bit, so reused levels write a used word.
  - No fee snapshot written on the source level of a flip.
  - The per-tick limit check reads the hook's own storage when levels don't share ticks.
  - No fee growth update for a token with no fees.
- What's left is mostly v4 initializing fresh ticks and positions: about 170k of the roughly 230k per operation in the worst case.
- `maxOpsPerSwap`: 9 on mainnet, 24 on L2s (DESIGN.md section 12). `skipDivisor` and the partial-flip threshold keep their starting values.
- `script/Deploy.s.sol`, tested end to end, and a README usage section.

## Phase 2: testnet and off-chain services

| # | Step | Branch | Status |
|---|---|---|---|
| 9 | Merge and housekeeping | `main` | Done |
| 10 | Fork tests on Unichain | `main` | Planned |
| 11 | Unichain Sepolia deployment | `main` | Planned |
| 12 | Indexer | `offchain` | Planned |
| 13 | Keeper bot | `offchain` | Planned |
| 14 | Testnet soak | both | Planned |
| 15 | Audit preparation | `main` | Planned |

### 9. Merge and housekeeping

- Restore the gas snapshot: `forge coverage` rewrites it with unoptimized numbers. Ignore coverage output files.
- Read the coverage report, and add tests for any branch that matters and isn't covered.
- Merge `feat/v1-contracts` into `main` and push. CI runs on GitHub from then on.

Outcome:
- Coverage needs a memory cap on a 16 GB machine: `solc` peaks at about 7 GB with `--ir-minimum`. Run it as `systemd-run --user --scope -p MemoryMax=7G forge coverage --ir-minimum --report lcov`, or in CI.
- Every line of the engine, the factory, the state base and `OrderMath` runs. The uncovered lines elsewhere are source-map artifacts of `--ir-minimum` (modifier bodies, assembly blocks).
- Three branches were untested and now have tests: the engine refusing a direct `scan`, an engine revert reaching the caller unchanged, and `positionOf` for someone with no shares.
- Left uncovered on purpose: `_projectedFeeGrowth` on a level with no liquidity (a view returning the stored growth), and the early returns of `_pay` and `_settleDeltas` for zero amounts.

### 10. Fork tests on Unichain

The unit tests use a PoolManager compiled for testing and v4's test routers. These tests use the real deployments on a fork of Unichain mainnet. They're opt-in: they run when `UNICHAIN_RPC_URL` is set.

- Deploy the factory and a hook against the deployed PoolManager. Check that each deployment transaction fits under 16.7M gas, Ethereum's per-transaction cap since Fusaka (EIP-7825), so the same deployment works on any chain.
- Swaps through the Universal Router, paid with Permit2, the way wallets and aggregators trade. Quotes from the V4Quoter, including swaps that flip levels.
- Real gas numbers for the main operations and the worst case, compared with the snapshot.
- The Uniswap addresses per chain in one place, shared by the scripts and the tests.

### 11. Unichain Sepolia deployment

- A testnet-only deployer key in the gitignored `.env`. It never goes to mainnet.
- Two mintable test tokens, the factory with `maxOpsPerSwap` 24, and one hook config.
- Scripts to seed orders and to trade through the Universal Router, so the testnet has activity without arbitrage bots.
- Contracts verified on the explorer. Addresses recorded in `deployments/unichain-sepolia.json`.

### 12. Indexer

A [Ponder](https://ponder.sh) indexer, the data source for the front end:

- Hooks from the factory's `HookCreated`, pools from the PoolManager's `Initialize` for those hooks.
- Groups, merges, levels and flips from the hook's events. Each user's shares per group, following `SharesConverted`.
- GraphQL and SQL APIs. Tests against a local chain.

### 13. Keeper bot

A TypeScript service with viem. It reads the chain directly, so it works without the indexer:

- After each block with activity on a TickTock pool, it simulates `flipCrossed`, and sends it if levels are left to flip.
- It simulates `flipLevel` for levels reported by `LevelSkipped`, and for the level the price stopped inside once 90% of it is sold.
- It only sends what its simulation says will succeed, with a gas price cap and a gas budget.
- Tests against a local chain with the real contracts.

### 14. Testnet soak

- Run the keeper and a scripted trader on Unichain Sepolia for several days.
- A script that checks the invariant suite's structure checks against live state.
- Fix what turns up, and redeploy if the contracts change.

### 15. Audit preparation

- Freeze the contracts and tag a release candidate.
- `docs/AUDIT.md`: the scope with line counts, the known issues, the invariants and how to run everything.
- Choosing and booking auditors is the owner's call. Auditors are usually booked weeks ahead, so it's worth contacting them during step 14.

## Later

- **The front end**, on its own branch, reading from the indexer.
- **Unichain mainnet**, after the audit.
- **The far-price mitigation** in DESIGN.md section 9, if the testnet shows it's needed.
