# Demeter V2

[中文版](README_ZH.md)

Demeter V2 is a permissionless onchain index-fund protocol. Anyone may create a
fund from assets approved by the global `AssetRegistry`; governance does not
approve individual pools.

## Status

The singleton core, tests, deployment scripts, and local release gates are
implemented. The repository is not authorization for a production deployment.
Production remains blocked on chain and asset selection, live oracle and TWAP
fork tests, governance-role verification, economic simulation, independent
security review, and deployed-bytecode verification.

## Architecture

- `DemeterManager` is the singleton custodian and reserve ledger for all pools.
- Every pool has a creator-bound `poolId` and a dedicated ERC-20
  `DemeterShare`.
- Issue inputs round up and redemption outputs round down against recorded
  reserves; redemption is never paused.
- `IndexPolicy` stores delayed, append-only creator policies within timelocked
  global bounds.
- `AuctionRebalance` executes bounded public Dutch auctions. The Manager has no
  public AMM swap, arbitrary calldata, or general DEX allowance.
- Chainlink provides the primary USD anchor and approved external Uniswap V3
  common-quote TWAPs provide cross-validation.
- `DemeterBasketRouter` supports only user-funded in-kind issue and redemption.

## Repository

```text
src/            V2 contracts, interfaces, types, and libraries
test/v2/        unit, integration, fuzz, and invariant tests
script/v2/      deployment, wiring, pool creation, and release gates
docs/           architecture, policy, operations, and release documentation
research/       non-production rebalancing comparison harness
```

The former V1 Factory/Beacon/Vault prototype is available only in Git history.

## Development

Requirements: Foundry with Cancun EVM support and Git submodules.

```bash
git submodule update --init --recursive
forge build
forge test --match-path 'test/v2/**' --summary
bash script/v2/check-format.sh
bash script/v2/check-contract-sizes.sh
```

The complete release commands and required outcomes are in the
[release checklist](docs/RELEASE_CHECKLIST_V2.md).

## Documentation

- [Architecture](docs/ARCHITECTURE_V2.md)
- [Implementation plan](docs/IMPLEMENTATION_PLAN_V2.md)
- [Rebalancing whitepaper](docs/REBALANCING_WHITEPAPER.md)
- [Architecture decisions](docs/DECISIONS.md)
- [Roadmap](docs/ROADMAP_V2.md)
- [Release checklist](docs/RELEASE_CHECKLIST_V2.md)
- [Release evidence](docs/RELEASE_EVIDENCE_V2.md)
- [Static-analysis triage](docs/STATIC_ANALYSIS_V2.md)
- [Incident runbook](docs/INCIDENT_RUNBOOK_V2.md)
- [Security policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md)

Canonical specifications are English. Synchronized Chinese mirrors are under
[`docs/zh`](docs/zh/).

## License

Demeter-owned source is licensed under the [MIT License](LICENSE). Vendored
Uniswap-derived math files retain their stated GPL license headers, and
dependencies retain their upstream licenses.
