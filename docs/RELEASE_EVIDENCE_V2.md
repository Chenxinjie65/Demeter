# Demeter V2 Release Evidence

[中文](zh/RELEASE_EVIDENCE_V2_ZH.md)

> Evidence date: 2026-09-06
>
> This is a local engineering gate record. It is not authorization to deploy
> production assets or accept user AUM.

## Verified local gates

The following commands were run sequentially from the repository root and
returned exit code zero:

```text
bash script/v2/check-format.sh
git diff --check
forge test --summary
FOUNDRY_PROFILE=release forge test --match-path 'test/v2/invariants/**' --summary
FOUNDRY_PROFILE=release forge test --match-path 'test/v2/libraries/V2Math.t.sol' --summary
forge build --sizes
bash script/v2/check-contract-sizes.sh
bash script/v2/check-slither.sh
canonical Markdown link check (README and docs)
```

The release invariant run used 2,000 sequences and 200,000 calls per invariant
harness. The release math run used 10,000 cases for each of the four arithmetic
fuzz properties. The full behavioral suite included both legacy regression tests
and the V2 suite; all reported zero failures.

The V2 runtime-size gate reported:

| Contract | Runtime bytes | Limit |
| --- | ---: | ---: |
| AssetRegistry | 5,549 | 6,000 |
| DemeterManager | 21,706 | 22,000 |
| IndexPolicy | 13,520 | 14,000 |
| AuctionRebalance | 23,481 | 23,500 |
| DemeterBasketRouter | 5,341 | 6,000 |

Slither 0.11.3 completed with `--fail-high`. Its 92 findings are retained in
the documented triage; no unresolved Critical/High V2 finding was reported by
the gate. This does not replace an independent audit.

The V2 interface NatSpec compile fixture passed after documenting units,
rounding direction, authorization, and lifecycle semantics for all public
interfaces.

## Delivery blockers

- The repository `.git` directory is read-only in the current environment.
  `git commit` cannot create `.git/index.lock`, so the per-slice commits required
  by `IMPLEMENTATION_PLAN_V2.md` are not present yet.
- No production chain, first approved asset set, live RPC, deployed Timelock
  roles, production fork fixtures, economic simulation report, or independent
  audit has been supplied. The release checklist therefore remains unsigned.
- The first-pool AUM limit is documented as an operational soft cap. It is not
  an onchain hard limit in the proportional issue path.

When Git and production configuration are available, rerun this evidence set,
add the production fork and simulation artifacts, obtain the independent audit,
and create the exact per-slice commits in the implementation plan.
