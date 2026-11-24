# TickTock

A Uniswap v4 hook for double-sided limit orders. A user deposits one token and picks two prices: the hook sells at the high price, buys back at the low price, and repeats forever, compounding the profit.

Status: in development, not audited. See [docs/DESIGN.md](docs/DESIGN.md) for the design, [docs/PLAN.md](docs/PLAN.md) for the build plan and [docs/SECURITY.md](docs/SECURITY.md) for security notes.

## How it works

- Each order is a one-tick v4 range. The hook is the only liquidity provider in its pools, and routers and arbitrage bots fill the orders as part of normal swaps.
- A strategy is a sell level `S` plus a spread from the hook's menu. It asks at `S`, bids at `S - spread` once the ask fills, asks again once the bid fills, and so on.
- When a swap fully crosses a level, the hook flips it in `afterSwap`: the filled orders move to the other side of their strategy, fees included. A per-swap budget caps the work; anything it doesn't reach waits for the next swap or a keeper.
- Users sharing a strategy side share a group and hold shares in it. Withdrawals always work, in or out of range.

## Contracts

| Contract | Role |
|---|---|
| `TickTockFactory` | One per chain. Deploys one hook per config (level spacing plus spread menu), as a minimal clone. |
| `TickTockHook` | One per config. Deposits, withdrawals, v4 callbacks, keeper functions and views. |
| `TickTockEngine` | The flip logic, which the hook runs with `delegatecall` to stay under the contract size limit. |

## Development

Requires [Foundry](https://getfoundry.sh).

```sh
git clone --recurse-submodules git@github.com:Strapontin/TickTock.git
forge build
forge test                       # unit, fuzz and invariant tests
FOUNDRY_PROFILE=ci forge test    # 10x the fuzz runs, deeper invariant runs (a few minutes)
forge test --mc GasTest          # refreshes snapshots/TickTock.json
```

The compiler settings are pinned in `foundry.toml`: solc 0.8.26, `cancun`, via-IR, 200 optimizer runs. Check that v4's `PoolManager` still compiles before changing the runs: some values hit "stack too deep" in v4's code.

## Deployment

Deploy a factory, and optionally a first config's hook, with the deploy script:

```sh
POOL_MANAGER=0x... MAX_OPS_PER_SWAP=24 LEVEL_SPACING=10 SPREADS=10,50,100 \
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --account <keystore>
```

- `MAX_OPS_PER_SWAP` is the most liquidity operations one swap's `afterSwap` may spend, fixed per factory. Use 9 on Ethereum mainnet and 24 on L2s. The worst case adds about 230k gas per operation to a swap (DESIGN.md section 12).
- Leave out `LEVEL_SPACING` and `SPREADS` to deploy only the factory. Set `FACTORY=0x...` to add a hook to an existing factory.
- A hook's address must carry its permission bits, so creating one needs a salt. The deploy script mines it. To mine one on its own: `FACTORY=0x... LEVEL_SPACING=10 SPREADS=10,50,100 forge script script/MineSalt.s.sol --rpc-url $RPC_URL`, then call `factory.createHook(levelSpacing, spreads, salt)`. Anyone can create a config's hook; each config gets exactly one.

## Using a hook

Pools use tick spacing 1, a static fee, and the hook's address. There's no need to create the pool: the first deposit does, at that order's price.

```solidity
// Approve the hook for the token you pay with (or send ETH for a native token0), then:
(uint64 groupId, uint256 shares) = hook.deposit(
    key,             // PoolKey: currency0, currency1, fee, tickSpacing = 1, hooks = hook
    sellLevel,       // S: a tick, a multiple of the config's level spacing
    spreadIndex,     // the strategy's spread, as an index in the config's menu
    startWithToken0, // true: ask at S with token0; false: bid at S - spread with token1
    amount,          // the most you pay; you pay what v4 asks for the liquidity
    minShares,
    recipient,
    deadline
);

hook.positionOf(user, groupId);                    // what the shares are worth now, fees included
hook.withdraw(groupId, shares, recipient, deadline); // in or out of range, before or after flips
```

Prices are token1 per token0: a level `L` trades at about `1.0001^L`. After a merge, a user's shares may have moved to another group: `withdraw` and `positionOf` follow it automatically, and `resolveGroup` says where they went.

## Keepers

These functions are permissionless. Users never lose funds when nobody calls them, but they can miss trades. A keeper bot can watch the events and call them:

| Function | When |
|---|---|
| `flipCrossed(key, maxOps)` | Swaps crossed more levels than their budget could flip. |
| `flipLevel(key, level)` | A level was skipped as small (`LevelSkipped`), or a swap stopped inside it after at least 90% was sold. |
| `movePrice(key, targetSqrtPrice)` | The price was pushed far away through empty space. It moves the price back in chunks. |

## License

[MIT](LICENSE)
