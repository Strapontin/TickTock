# TickTock off-chain services

This branch adds two services to the contracts:

| Package | What it does |
|---|---|
| [indexer/](indexer) | A [Ponder](https://ponder.sh) indexer: hooks, pools, groups, positions, the order book, and the history of every hook event. The data source for the front end. |
| [keeper/](keeper) | The keeper bot. It flips what swaps leave behind: levels over a swap's budget, levels a scan skipped as small, and levels the price stopped inside after 90% sold. |
| [shared/](shared) | The ABIs (generated from the contracts), the deployment file loader, strategy and tick math, and the test harness. |

Both read a deployment file written by `script/testnet/DeployTestnet.s.sol` (by default `deployments/unichain-sepolia.json`). They work independently: the keeper reads the chain directly.

## Setup

Requires Node 22.12 or later, and [Foundry](https://getfoundry.sh) for the tests.

```sh
forge build              # at the repository root: the ABIs and the testnet scripts
cd offchain
npm ci
npm run abis             # regenerates shared/src/abis.ts after a contract change; CI checks it's current
```

Versions are pinned exactly (`.npmrc`), and only to releases at least two weeks old when added.

## Indexer

```sh
cd offchain/indexer
npm run dev              # local development: PGlite in .ponder/, http://localhost:42069
DATABASE_URL=postgres://... npm start -- --schema ticktock   # production
```

| Variable | Default |
|---|---|
| `TICKTOCK_DEPLOYMENT` | `deployments/unichain-sepolia.json` |
| `PONDER_RPC_URL` | `https://sepolia.unichain.org` |
| `DATABASE_URL` | Unset: PGlite, for development only |

APIs:

- `/graphql`: every table, with relations (GraphiQL in a browser).
- `/sql/*`: read-only SQL for `@ponder/client`.
- `/positions/:owner`: a user's positions, each with its group.
- `/book/:poolId`: every level with liquidity, lowest first.
- `/ready` and `/status`: readiness and the last indexed block.

How state is kept:

- **Slots follow the events.** Which group holds which side of each strategy is updated from the events: a flip moves a strategy's group to its other side, and the survivor of a merge takes the destination.
- **Amounts come from the hook.** Liquidity, pending tokens and shares are read from the hook (`getGroup`, `getLevel`) at the end of each event's block, so they never drift from what the hook stores.
- **Swaps are indexed only for the deployment's pools.** The PoolManager emits swaps for every pool on the chain, so the indexer filters them by pool id.

Ponder 0.18 depends on packages with published advisories: `drizzle-orm`, `vite`, `@hono/node-server` and `graphql-yoga`. Most are in features the indexer doesn't use, like static file serving, the Vite dev server, or SQL identifiers built from user input. Ponder's latest release pins the same versions. Until it updates them, put the API behind a reverse proxy that only forwards the routes above, and don't expose `ponder dev`.

## Keeper

```sh
cd offchain/keeper
KEEPER_DRY_RUN=1 npm start   # simulate only
npm start
```

It loads the repository's `.env`. Settings:

| Variable | Default |
|---|---|
| `TICKTOCK_DEPLOYMENT` | `deployments/unichain-sepolia.json` |
| `KEEPER_RPC_URL` | `https://sepolia.unichain.org` |
| `KEEPER_PRIVATE_KEY` | Falls back to `PRIVATE_KEY`, the testnet key |
| `KEEPER_POLL_MS` | 2000 |
| `KEEPER_MAX_OPS` | The factory's `maxOpsPerSwap` (at least 9) |
| `KEEPER_MAX_GAS_PRICE_GWEI` | 1 |
| `KEEPER_START_BLOCK` | The deployment's start block |
| `KEEPER_DRY_RUN` | Unset. `1` simulates only |

Each run:

1. Reads the logs since the last run: new hooks, new pools, activity, and `LevelSkipped`.
2. For each pool with activity, calls `flipCrossed` until nothing crossed is left, then tries `flipLevel` on the level the price is inside.
3. Retries `flipLevel` on every skipped level until it flips or isn't crossed any more.

It only sends what its simulation says will succeed and do work, one transaction at a time. Above the gas price cap it waits, and keeps the work for the next run.

The keeper's state lives in memory, so a restart reads the logs again from `KEEPER_START_BLOCK`.

The protocol pays keepers nothing (DESIGN.md section 5.3), so running one costs gas. On the testnet that's negligible.

## Tests

```sh
cd offchain
npm test
```

The tests use a local chain:

1. Anvil forks Unichain Sepolia at a pinned block. The public RPC is used the first time; anvil caches the state after that.
2. The repository's own scripts deploy and seed TickTock.
3. The tests drive the chain from there.

What they cover:

- **Shared:** the tick math port, against v4-core's source and its known prices.
- **Indexer:** every indexed group, slot, position and level must match the hook's state, after a backfill and in realtime. The activity includes merges and a withdrawal that converts merged shares.
- **Keeper:**
  - Leftovers from a swap's budget.
  - A level a scan skipped.
  - A level 90% sold, and one that isn't.
  - Dry runs, and the gas price cap.
