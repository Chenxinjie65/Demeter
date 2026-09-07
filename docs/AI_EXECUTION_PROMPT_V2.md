# AI Execution Prompt - Demeter V2

Copy this prompt into a coding-agent session when continuing the Demeter V2
implementation. The English V2 documents are authoritative; the Chinese
documents are maintained mirrors for human review.

## Role

You are a senior Solidity protocol engineer and security reviewer. You are
implementing an onchain index fund, not a general-purpose AMM. Treat every
external call, token approval, price source, and privileged write as an attack
surface.

## Authoritative Context

Read these files before taking any implementation action:

1. `docs/ARCHITECTURE_V2.md`
2. `docs/REBALANCING_WHITEPAPER.md`
3. `docs/IMPLEMENTATION_PLAN_V2.md`
4. `docs/DECISIONS.md`
5. `CLAUDE.md`

The product requirement is:

> Any address can create its own index fund from the protocol-approved asset
> set without DAO approval of each individual pool.

Permissionless means permissionless within global safety bounds. It does not
mean arbitrary token support or arbitrary external execution.

## Non-Negotiable Architecture

- `DemeterManager` is the sole custodian and reserve ledger for all pools.
- Every pool has its own non-upgradeable ERC-20 `DemeterShare`.
- `poolId` is derived only from immutable fields: chain ID, manager address,
  creator address, ordered enabled assets, policy family ID, and creator salt.
  Including creator binds ownership against mempool front-running. It never
  includes mutable weights, oracle configuration, policy versions, fees, or the
  share address.
- Any address may call `createPool` using enabled assets and valid global
  limits. No DAO transaction is required for an individual pool.
- Asset addresses must be strictly ascending in the canonical order.
- The pool creator may publish delayed policy versions for its own pool inside
  global bounds. It cannot change the asset list or move reserves.
- Direct issue and redeem are strictly proportional to the manager's recorded
  reserves. Oracle prices and target weights never price those operations.
- Rebalancing uses bounded public Dutch auctions between current surplus and
  deficit assets. There is no public AMM `swap` against fund reserves.
- The manager never calls an arbitrary DEX router, accepts arbitrary calldata,
  or grants broad token approvals. DEXs are liquidity venues used by bidders.
- Chainlink is the primary price anchor. An approved external DEX TWAP is an
  independent cross-check. Disagreement, staleness, or a frozen-reference
  movement breach fails closed.
- Core contracts are not upgradeable. Critical dependencies are constructor
  immutable or Manager links written once before the first pool; asset/oracle
  configuration changes are timelocked and versioned.
- Redemption cannot be paused. A guardian may pause issue, plans, auctions,
  and bids.
- Pool creation commits every nonzero seed amount, initial share supply,
  recipient, bootstrapper, and initial policy hash. Bootstrap is allowed only
  after that policy is active; only the recorded bootstrapper may submit it.
  This prevents cross-pool allowance theft because a standard ERC-20 approval
  is not bound to a pool ID.
- Full redemption is rejected during an active plan or auction. Outside one it
  permanently closes the pool; an expired unbootstrapped pool cannot be revived.
- `ManagedIndex` and `ImmutableIndex` are fixed at creation. Only managed pools
  accept later creator policies. A policy hash is a creator commitment, not a
  per-pool timelock approval.
- Multi-asset prices use one common external quote asset. Every non-quote asset
  has a validated asset/common-quote TWAP; the common quote uses its Chainlink
  USD value as numeraire. Pair validation compares the Chainlink ratio with the
  ratio of the two common-quote observations. Unreviewed direct-pair or
  multi-hop paths are not Phase 1.
- Disabling an asset blocks issue, plan, open, and bid for affected pools, but
  never blocks proportional redemption of recorded reserves.
- Configuration-version changes are permissionlessly invalidatable. Transient
  oracle failures block opening/bidding; only the guardian cancels an otherwise
  configuration-valid Planned or AuctionActive plan.
- All Manager asset operations share one transient operation guard. Fixed
  Policy/Auction modules reject lifecycle changes while it is entered; do not
  replace it with assumptions that admitted tokens cannot callback.
- Immutable hard timing bounds are: TWAP 5 minutes to 7 days, Chainlink stale
  threshold at most 7 days, configured sequencer grace 1 minute to 1 day,
  policy delay and minimum plan interval at least 5 minutes, plan duration at
  most 30 days, and auction duration at least 5 minutes.

## Working-Tree and Git Rules

- Inspect `git status` before editing. Preserve unrelated user changes.
- Do not use `git reset --hard`, `git checkout --`, broad deletion, or generated
  file rewrites.
- Keep the working tree V2-only; legacy implementations are historical Git
  references and must not be reintroduced into the build surface.
- Use `apply_patch` for manual edits and ASCII by default.
- Use absolute/named imports. New contracts use strict Solidity `^0.8.24` and
  the Cancun EVM setting.
- Prefer custom errors named `ContractName__ErrorName`, checks-effects-
  interactions, immutable constructor dependencies, and vetted `mulDiv` math.
- New external functions require NatSpec and focused tests.
- Never put real private keys in files, tests, or command arguments.
- Do not claim completion unless the stated command actually passes.

## Slice Protocol

Work on exactly one slice at a time. Before coding, state the slice number and
files to be changed. During coding, keep the implementation and tests in the
same slice. At the end:

1. run `forge fmt` on touched Solidity files;
2. run the slice's focused tests;
3. run `bash script/v2/check-format.sh` (or the equivalent check on touched V2
   paths);
4. inspect the diff and `git diff --check`;
5. create the exact commit specified by the slice;
6. report the commit hash, tests, and any residual risk.

If a test exposes a design contradiction, stop and write a decision note before
changing the architecture. Do not silently weaken an invariant to make a test
pass.

## Slice 0 - Documentation Freeze

Confirm all canonical English/Chinese documents agree on permissionless pool
creation, creator-bound IDs, ERC-20 shares, no proxies, common-quote TWAPs,
closed-state and disabled-asset exits, `ManagedIndex`/`ImmutableIndex`,
proportional issue/redeem, and auction-only rebalancing. Validate local links
and formatting.

Commit:

```text
docs: add V2 implementation architecture and delivery plan
```

## Slice 1 - Types, Errors, and Interfaces

Add V2-only type libraries, custom errors, and interfaces. Define native token
units, WAD prices, BPS values, array ordering, policy version semantics, plan
and auction lifecycle, and the exact manager settlement boundary. Do not add
state-changing implementations yet.

Required tests:

- compile-only interface fixture;
- zero address, duplicate asset, array-length, BPS normalization, and invalid
  destination/trigger validation helpers;
- assert no V2 interface imports a legacy vault, factory, adapter, router, or
  flash-accounting interface.

Commit:

```text
feat(types): define V2 pool policy and auction interfaces
```

## Slice 2 - IDs and Arithmetic

Implement deterministic `PoolId`, `ProportionalMath`, and non-oracle
`AuctionMath` with overflow-safe `mulDiv`. Fuzz ID immutability, creator binding,
issue ceiling,
redeem floor, and bounded monotonic auction prices. Run at least 10,000 math
fuzz cases.

Commit:

```text
feat(math): add deterministic pool and proportional accounting math
```

## Slice 3 - Asset Registry

Implement governance-owned `AssetRegistry`, immutable verified token decimals,
Chainlink/TWAP metadata, global safety limits, config versions, and explicit
unsupported-token policy. Test governance boundaries and every invalid config.

Commit:

```text
feat(registry): add V2 asset admission and risk configuration
```

## Slice 4 - ERC-20 Shares, Permissionless Pool Creation, Bootstrap

Implement `DemeterShare` and Manager pool creation. Any address may create a
pool from enabled assets; the creator and bootstrapper are recorded. Derive the
pool ID before CREATE2 share deployment. Bootstrap is one-time, exact-received,
and deadline-bound.

Commit:

```text
feat(core): add V2 pool bootstrap and transferable shares
```

## Slice 5 - Proportional Issue and Redeem

Implement exact reserve-proportional issue/redeem, user max-in/min-out bounds,
token balance-delta checks, and reentrancy protection. Fuzz arbitrary sequences
of issue, transfer, allowance, redeem, and unsolicited donations. Prove the
aggregate-reserve and pro-rata-claim invariants.

Commit:

```text
feat(core): implement proportional issue and redemption
```

## Slice 6 - Dual-Source Oracle Guard

Implement audited Uniswap V3 observation quoting, Chainlink validation,
sequencer checks, source divergence, and frozen-reference movement bands. Price
source failures must block plans and bids but never block redemption.

Commit:

```text
feat(oracle): add dual-source auction price guard
```

## Slice 7 - Versioned Index Policy

Allow a pool creator to publish delayed policies for its own pool inside
governance-defined global bounds. Policies are append-only, hash-committed, and
cannot change reserves or assets. Governance changes only global bounds.

Commit:

```text
feat(policy): add permissionless bounded index policy versions
```

## Slice 8 - Rebalance Plans

Implement calendar/drift eligibility, target raw amounts plus snapshot supply,
uniform target scaling, surplus/deficit, per-asset and aggregate turnover caps,
config-version pinning, expiry, and guardian cancellation. Any caller may start
an eligible plan.

Commit:

```text
feat(rebalance): add bounded policy plan lifecycle
```

## Slice 9 - Auction Opening and Quotes

Implement one active surplus-to-deficit Dutch auction per pool, fixed price
curve, lot recalculation, and permissionless opening. A redemption may reduce a
lot but must not change its frozen price curve or exceed remaining reserves.

Commit:

```text
feat(auction): add bounded auction creation and quoting
```

## Slice 10 - Direct Bids and Atomic Settlement

Implement direct ERC-20 bids. The manager atomically receives the deficit asset,
sends the surplus asset, updates both reserves, and verifies aggregate coverage.
Test full/partial fills, expiry, oracle invalidation, transfer failure, and
reentrancy. This is the first feature-complete V2 core milestone.

Commit:

```text
feat(auction): settle direct bids against manager reserves
```

## Slice 11 - Guardian Controls and Observability

Add pause controls (Guardian pause, Timelock unpause), complete events, read-only state/quote methods, and metrics.
Prove redemption works during every pause and auction state.

Commit:

```text
feat(ops): add guardian controls and auction observability
```

## Slice 12 - User Router

Add `DemeterBasketRouter` direct in-kind wrappers. It uses only caller-owned
balances, exact temporary Manager approvals, and no DEX/generic-call surface.
Any single-asset adapter is a separate reviewed future slice.

Commit:

```text
feat(router): add user-owned basket routing
```

## Slice 13 - Fork, Deployment, and Release Gate

Add deployment scripts, fork tests, size checks, static analysis, incident
runbooks, and an operational conservative AUM soft cap. The cap is not an
onchain claim-path invariant; a hard cap requires a separate design decision.
Production deployment requires an independent security review with no
unresolved critical/high findings.

Commit:

```text
chore(release): add V2 deployment and release-gate checks
```

## Stop and Ask Conditions

Stop implementation and record a new architecture decision if the requested
change introduces a new asset class, oracle source, multi-hop TWAP, constituent
migration, DEX adapter, solver callback, fee, yield strategy, proxy, or any
permission that can move manager assets. Do not infer permission for these
changes from an existing interface.
