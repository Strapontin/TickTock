# TickTock

A Uniswap v4 hook for double-sided limit orders. A user deposits one token and picks two prices: the hook sells at the high price, buys back at the low price, and repeats forever, compounding the profit.

Status: in development, not audited. See [docs/DESIGN.md](docs/DESIGN.md) for the design, [docs/PLAN.md](docs/PLAN.md) for the build plan and [docs/SECURITY.md](docs/SECURITY.md) for security notes.

## Development

Requires [Foundry](https://getfoundry.sh).

```sh
git clone --recurse-submodules git@github.com:Strapontin/TickTock.git
forge build
forge test
```

## License

[MIT](LICENSE)
