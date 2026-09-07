# Demeter V2 Implementation Plan

[中文](zh/IMPLEMENTATION_PLAN_V2_ZH.md)

> Status: Binding implementation plan for the V2 auction-based index fund.
>
> Revision date: 2026-09-05
>
> Audience: AI coding agents and reviewers. Every slice is independently
> buildable, tested, and committed before work begins on the next slice.

## 1. Rules for Every Slice

1. Read `ARCHITECTURE_V2.md`, `REBALANCING_WHITEPAPER.md`, and this document
   before changing V2 code.
2. V2 work is performed on the V2-only working tree; legacy contracts remain
   available only through historical Git commits.
   Put new code in the V2 paths below. Legacy removal is a separate, reviewed
   migration task after V2 replacement coverage exists.
3. Use Solidity `^0.8.24`, Foundry, custom errors, and explicit NatSpec on
   external interfaces. Code and canonical documents are English; every
   canonical document has a synchronized Chinese mirror under `docs/zh/`.
4. A slice includes implementation, focused unit tests, fuzz or invariant tests
   proportional to the risk, `forge fmt`, and the exact test command below.
5. Do not use `vm.assume` to hide a correctness bug. Bound fuzz inputs or prove
   the precondition in the test.
6. No generic `call`, `delegatecall`, router approval, external asset strategy,
   callback, or public AMM swap is permitted in Phase 1.
7. Commit only after the slice's completion command passes. One commit equals
   one behaviorally coherent slice. Do not mix formatting-only or legacy edits
   into an implementation commit.

The required completion command for a normal slice is:

```bash
bash script/v2/check-format.sh && forge test --match-path '<focused-test-path>' -vvv
```

At each milestone and before merge, run:

```bash
bash script/v2/check-format.sh && forge test -vvv
```

The canonical all-V2 formatting path list is maintained in
`script/v2/check-format.sh`. Legacy prototypes are outside this formatting
gate but remain inside the full behavioral test command.

## 2. Source Layout

New V2 code uses these paths. Existing similarly named legacy paths are not
extended unless a slice explicitly says to adapt a narrowly scoped utility.

```text
src/
  core/
    AssetRegistry.sol             # Asset admission, risk configuration, guardian
    DemeterManager.sol            # Sole custodian and reserve ledger
    DemeterShare.sol              # Per-pool ERC-20 claim, manager mint/burn only
    IndexPolicy.sol               # Creator policy versions within global bounds
    AuctionRebalance.sol          # Plan and auction state; no token custody
    DemeterBasketRouter.sol       # Direct user-owned in-kind routing only
  oracle/
    UniswapV3TwapOracle.sol       # Stateless approved-pool TWAP adapter
  interfaces/
    IAssetRegistry.sol
    IDemeterManager.sol
    IDemeterShare.sol
    IIndexPolicy.sol
    IAuctionRebalance.sol
    IDemeterBasketRouter.sol
    ITwapOracle.sol
    external/
      IChainlinkAggregator.sol
      IUniswapV3Pool.sol
  libraries/
    PoolId.sol
    ProportionalMath.sol
    AuctionMath.sol
    OracleGuard.sol
    V2Validation.sol
    V2Errors.sol
  types/
    PoolTypes.sol
    RebalanceTypes.sol
test/
  v2/
    core/
    oracle/
    libraries/
    invariants/
    integration/
  v2/mocks/
```

## 3. Contract Boundaries

### 3.1 `AssetRegistry`

**Owns:** supported assets, verified ERC-20 decimals, Chainlink feed, maximum
feed staleness, one approved Uniswap V3 pool against the registry-wide common
quote asset for each non-quote asset, TWAP window, divergence limits,
frozen-plan movement limits,
governance timelock, and guardian address.

**Writes:** governance timelock only for global asset configuration and global
pool bounds. A risk admin may prepare proposals offchain but has no direct
Phase-1 write permission.

**Never does:** custody, share math, plan creation, auction pricing, or token
approvals.

`AssetConfig` requires nonzero contracts, a token whose `decimals()` has been
read and stored once, a common quote asset which is itself enabled, and bounded
BPS and time values. Asset admission is a governance decision backed by an
offchain liquidity review; a contract cannot prove historical pool depth.
The Registry constructor rejects an EOA timelock. Hard timing bounds are 5
minutes to 7 days for TWAP windows, at most 7 days for Chainlink staleness, and
1 minute to 1 day for a configured L2 sequencer grace period.

### 3.2 `DemeterShare`

**Owns:** ERC-20 `totalSupply`, balances, and allowances for one `poolId`.

**Writes:** holders may transfer and approve; only its immutable manager may
mint and burn.

**Never does:** hold fund assets, inspect target weights, or call external
contracts. It uses a fixed 18 decimals and is deployed by `DemeterManager`
with `CREATE2`.

### 3.3 `DemeterManager`

**Owns:** every recorded pool reserve, the aggregate recorded reserve per
underlying asset, pool metadata, asset ordering, bootstrap status, registered
share token, and the one-time-frozen auction-settlement authority.

**Writes:**

- any address creates a pool from enabled assets within global limits;
- the timelock configures policy and auction authorities once before any pool exists;
- the recorded bootstrapper performs a one-time exact seed transfer after the
  initial policy is active; a relayer cannot safely substitute because a
  standard ERC-20 allowance is not bound to a pool ID;
- any user issues or redeems proportionally;
- `AuctionRebalance` alone invokes `settleAuctionBid`.

**Never does:** call a DEX, store a target weight, price a share from an oracle,
receive arbitrary external call data, or let another module move assets outside
the settlement function.

The manager uses a global `accountedReserve[asset]`. Before every outgoing
transfer it proves:

```text
IERC20(asset).balanceOf(address(manager)) >= accountedReserve[asset]
```

after all local reserve changes. Unsolicited token transfers are not a pool
reserve and cannot be redeemed until a future governed excess-sweep policy is
specified.

### 3.4 `IndexPolicy`

**Owns:** an append-only policy-version sequence for each pool and the current
active version. It has no asset custody.

Each policy contains an epoch, normalized target weights in canonical asset
order, a creator commitment hash, a policy family ID, and
`triggerBps`, `destinationBps`, `minPlanInterval`, `planDuration`, per-asset
and plan-wide turnover limits, auction curve limits, and oracle guard limits.

The pool creator publishes a policy with `effectiveAt`. `AuctionRebalance` may
use it only after that time. The contract permits at most one pending policy per
pool and never rewrites a published version. Governance sets global policy
bounds; it does not approve individual pool policies.

Immutable hard limits require at least 5 minutes for policy delay and minimum
plan interval, at most 30 days for plan duration, and at least 5 minutes for an
auction. Deployment policy may impose stricter values.

`policyFamilyId` is enabled or disabled globally by the timelock. A disabled
family cannot be used for new policies, but already active policies remain
readable; plans using a changed family or configuration are invalidated and
must close safely.

### 3.5 `AuctionRebalance`

**Owns:** plans and auction state, including reference snapshots, target raw
amounts plus snapshot share supply, consumed turnover, plan nonce, auction
nonce, and one active auction per pool.

**Writes:** public callers can start an eligible plan, open a valid current
surplus-to-deficit auction, bid, expire it, or invalidate a stale plan when its
pinned configuration changes. Guardian can cancel a Planned or AuctionActive
plan and pause new plan/auction actions.

**Never does:** take temporary custody, approve a DEX, call a solver callback,
or change a policy bound.

For a bid, it computes the fill first, calls the manager once, and then writes
the post-fill auction state. The manager function performs both ERC-20
transfers atomically:

```text
bidder -- buyAsset --> manager
manager -- sellAsset --> bidder
```

Both contracts use reentrancy protection. Phase 1 supports standard ERC-20
tokens only. Governance attests token behavior at admission, while runtime
exact-balance-delta checks reject fee-on-transfer and balance-changing behavior.
The Manager exposes its transient operation state to the fixed Policy and
Auction modules so a token callback cannot activate a policy, start a plan,
invalidate a valid plan, or cancel an auction between checks and settlement.

### 3.6 Oracle Components

`UniswapV3TwapOracle` is a stateless adapter. Given a registry-approved pool,
base asset, quote asset, amount, and window, it calls `observe()` and returns a
quote. Its calculations must be adapted from audited Uniswap V3 `OracleLibrary`
and fixed-point math, with the license preserved. Do not implement bespoke tick
math from first principles.

`OracleGuard` is a library used by `AuctionRebalance`. It normalizes Chainlink
prices to WAD, validates feed freshness and L2 sequencer status, derives the
Chainlink pair quote, obtains the TWAP pair quote, and applies divergence and
frozen-reference movement checks.

### 3.7 `DemeterBasketRouter` and Future Solver Adapter

`DemeterBasketRouter` wraps direct in-kind issue and redeem only. It uses exact
temporary Manager allowances and ends each successful call with zero balances
and allowances. A future single-asset or solver adapter must be distinct,
reviewed, and unable to move Manager assets outside direct-bid constraints.

## 4. Canonical Data and Deployment Order

### 4.1 Core Types

`PoolTypes.sol` defines `PoolKind`, `PoolKey`, `CreatePoolParams`, `IssueParams`,
`RedeemParams`, `PoolConfig`, `AssetConfig`, and `GlobalPoolBounds`.
`PoolConfig` fixes `IMMUTABLE_INDEX` or `MANAGED_INDEX` at creation; the kind
cannot be changed. `RebalanceTypes.sol` defines `PolicyParams`,
`GlobalPolicyBounds`, `PolicyVersion`, `PriceSnapshot`, `RebalancePlan`,
`Auction`, and `BidParams`.

Dynamic arrays are accepted only at pool and policy creation. Runtime storage
uses the canonical pool asset order plus per-asset mappings for reserves,
weights, targets, and snapshots. Do not store an unbounded user-provided array
in a hot bid path.

Every BPS value is `uint16`; all normalized monetary prices and pair quotes are
WAD (`1e18`). Token amounts remain in native token units. Conversions must use
`mulDiv` with an explicitly documented rounding direction.

### 4.2 Pool Identity and Share Deployment

The previous draft incorrectly included the share address in `poolId` while
also deriving the share deployment from `poolId`. V2 uses the acyclic identity:

```text
poolId = keccak256(
    chainId,
    address(manager),
    creator,
    orderedAssets,
    policyFamilyId,
    creatorSalt
)
```

The canonical encoding is `abi.encode(block.chainid, address(manager),
msg.sender, orderedAssets, policyFamilyId, creatorSalt)`. `msg.sender` is the
immutable creator; `createPool` does not accept an arbitrary creator field.
Asset addresses must be strictly ascending. A creator may choose a separate
nonzero bootstrapper, but that account must approve the Manager and call
`bootstrap` itself. A relayer would require a pool-bound signature/witness
mechanism, which is deferred from Phase 1.

`DemeterManager` deploys `DemeterShare` through `CREATE2` with `poolId` as the
salt. The resulting share address is stored in `PoolConfig` after deployment;
it is not part of the identity preimage.

### 4.3 Deployment Sequence

1. Deploy an OpenZeppelin `TimelockController` and establish the governance
   multisig/proposer/executor configuration.
2. Deploy `AssetRegistry` owned by the timelock, then configure guardian.
3. Deploy `DemeterManager` with immutable registry and timelock addresses.
4. Deploy `IndexPolicy` with a timelock-only global-bounds authority and
   permissionless creator publication, referencing the manager and registry for
   pool-order validation.
5. Deploy `UniswapV3TwapOracle` and `AuctionRebalance` with immutable manager,
   policy, registry, and TWAP adapter addresses.
6. Timelock atomically calls the manager's one-time `setIndexPolicy` and
   `setAuctionRebalance` before the first pool is created. The manager rejects
   replacements forever.
7. Timelock enables assets and policy families in the registry/policy contract.
   Any address can then create a pool, publish a matching initial bounded policy,
   wait for its `effectiveAt`, and have the recorded bootstrapper bootstrap the
   committed seed basket before the chosen deadline.

The deployment script must assert every address link and every one-time state
flag before broadcasting a pool-creation transaction.

The checked-in operational sequence is:

1. `script/v2/DeployV2Core.s.sol` deploys immutable core contracts;
2. `script/v2/WireV2Core.s.sol` schedules and executes the two Manager links;
3. governance enables the common quote, other assets, and policy family;
4. `script/v2/CreateV2Pool.s.sol` creates a creator-bound pool and publishes
   its committed policy v1;
5. after `effectiveAt`, `script/v2/ActivateAndBootstrapV2Pool.s.sol` activates
   policy v1 and seeds the exact committed basket.

## 5. AI Execution Plan

### Slice 0: Documentation Freeze

**Deliver:** this plan, the contract-boundary table in `ARCHITECTURE_V2.md`,
and the corrected acyclic `poolId` definition.

**Tests:** no Solidity behavior changes. Run `git diff --check` and confirm
every Markdown link to a local file resolves.

**Commit:**

```text
docs: add V2 implementation architecture and delivery plan
```

### Slice 1: V2 Types, Errors, and Interfaces

**Implement:** `PoolTypes.sol`, `RebalanceTypes.sol`, V2-specific custom errors,
and skeletal interfaces. Define exact units and rounding in NatSpec. Do not
implement a core contract yet.

**Tests:** compile-only interface fixture and unit tests for type validation
helpers: duplicate assets, zero addresses, length mismatch, BPS normalization,
and invalid `destinationBps >= triggerBps`.

**Complete when:** `forge build` succeeds and no V2 interface imports a legacy
vault, adapter, router, or flash-accounting interface.

**Commit:**

```text
feat(types): define V2 pool policy and auction interfaces
```

### Slice 2: Deterministic IDs and Arithmetic Libraries

**Implement:** `PoolId`, `ProportionalMath`, and the non-oracle parts of
`AuctionMath`. Use a vetted `mulDiv` implementation and expose only functions
with documented rounding direction.

**Tests:**

- same immutable pool key always derives the same ID;
- changing chain, manager, asset order, policy family, or salt changes the ID;
- `poolId` is independent of mutable policy weights and share address;
- issue uses ceiling and redeem uses floor;
- no overflow or division-by-zero across bounded fuzz inputs;
- linear auction price is `Pstart` at start, `Pend` at end, monotonic between,
  and never below `Pend`.

**Complete when:** library fuzz tests pass with 10,000 runs for arithmetic
tests, configured in the local test or Foundry profile.

**Commit:**

```text
feat(math): add deterministic pool and proportional accounting math
```

### Slice 3: Asset Registry and Test Tokens

**Implement:** `AssetRegistry`, `IAssetRegistry`, Chainlink and Uniswap pool
interfaces, and V2 fixtures for standard, fee-on-transfer, balance-changing,
and callback tokens. Store verified token decimals at admission and make them
immutable.

**Tests:**

- only timelock can add, disable, or configure an asset;
- zero addresses, invalid decimals, zero TWAP window, invalid BPS, disabled
  quote assets, and self-referential TWAP configuration revert;
- configuration updates cannot alter stored decimals;
- guardian rotation is timelock-only;
- exact balance-delta checks reject fee-on-transfer and balance-changing
  behavior at runtime; callback fixtures cannot mutate Manager, Policy, or
  Auction state during an asset operation. Governance admission and the
  production-asset gate still exclude these token classes.

**Complete when:** all manager code can depend on the registry for a canonical
asset order and immutable decimal metadata, without any price read.

**Commit:**

```text
feat(registry): add V2 asset admission and risk configuration
```

### Slice 4: Share Token, Pool Creation, and Bootstrap

**Implement:** `DemeterShare`, minimal `DemeterManager`, permissionless
`createPool`, and `bootstrap`. The Manager uses `CREATE2` to deploy each share; a pool stores
its fixed canonical asset order, share address, creator, bootstrapper, committed
seed hash, initial policy hash, initial share supply, share recipient, and
deadline. The creator address is part of the pool ID preimage so a copied
mempool transaction cannot let a frontrunner claim ownership.

**Tests:**

- any address can create a valid pool from enabled assets;
- duplicate `poolId` rejection and global pool-parameter bounds;
- a copied create transaction from a different creator derives a different ID;
- pools reject disabled, duplicate, or unordered assets;
- predicted and deployed share addresses match;
- only the manager mints/burns; holders retain normal transfer/allowance
  semantics;
- only the named bootstrapper may trigger bootstrap once before deadline; funds
  are pulled from that same account (the creator may choose itself or another account);
- every seed amount and initial share supply is nonzero and in bounds;
- bootstrap is rejected until the matching initial policy is active;
- a different caller cannot submit bootstrap on behalf of the recorded
  bootstrapper; this prevents cross-pool ERC-20 allowance theft;
- a regression test creates a pool naming another account as bootstrapper and
  proves an attacker cannot consume that account's Manager allowance;
- an expired unbootstrapped pool cannot be revived;
- full redemption is rejected during an active plan and closes the pool
  permanently when no plan is active;
- bootstrap rejects wrong array length, zero seed asset, and received amount
  differing from the requested amount;
- a pool cannot be used for issue/redeem before bootstrap.

**Complete when:** one bootstrapped two-asset pool has exactly matching manager
reserve, aggregate reserve, and ERC-20 balances.

**Commit:**

```text
feat(core): add V2 pool bootstrap and transferable shares
```

### Slice 5: Proportional Issue and Redeem

**Implement:** manager `issue` and `redeem`, including caller-supplied
`maxAmountsIn` and `minAmountsOut`. Use checks-effects-interactions,
OpenZeppelin `SafeERC20`, exact received-amount checks, and reentrancy protection.

**Tests:**

- issue requires every asset at `ceil(reserve * shares / supply)`;
- redeem returns every asset at `floor(reserve * shares / supply)`;
- user max/min bounds, insufficient share balance, zero shares, and incorrect
  array length revert;
- a direct donation changes ERC-20 balance but not issue/redeem quotes;
- failed token transfer reverts all accounting changes;
- two users issuing and redeeming in arbitrary order cannot extract more than
  their pro-rata claim plus documented bounded dust.

**Invariant harness:** random sequences of issue, transfer, approve,
transferFrom, redeem, and donation. After every action: aggregate recorded
reserves are covered by manager balances; share supply equals the share token;
all pool reserves are nonnegative by construction.

**Complete when:** unit tests plus `forge test --match-path test/v2/invariants/ProportionalClaimsInvariant.t.sol -vvv` pass for at least 1,000 invariant runs.

**Commit:**

```text
feat(core): implement proportional issue and redemption
```

### Slice 6: Chainlink and Uniswap V3 TWAP Guard

**Implement:** `UniswapV3TwapOracle`, `ITwapOracle`, and `OracleGuard`. Adapt
the audited Uniswap V3 observation and tick-quote calculation. Add only the
minimal vendored code required and preserve origin/license headers.

The common quote is the numeraire: it has a validated Chainlink USD feed but no
quote/quote TWAP. Each non-quote asset has an approved asset/common-quote TWAP;
pair validation compares the Chainlink ratio with the ratio of those common-
quote observations.

**Tests:**

- Chainlink answer <= 0, stale round, incomplete round, feed revert, and bad
  decimals revert;
- L2 sequencer down and grace-period cases revert;
- each non-quote asset uses its configured asset/common-quote pool and window;
- an `X/Y` quote is derived from two common-quote observations with correct
  token direction and decimal normalization;
- Chainlink pair quote and the derived TWAP pair quote pass within divergence
  and fail one BPS beyond it;
- frozen plan reference movement is inclusive at the limit and fails beyond it;
- no `issue` or `redeem` test needs a price source.

**Complete when:** oracle guard tests use mocks for every failure mode and at
least one mainnet-fork test verifies each approved feed/pool pair's decimal and
token-order configuration.

**Commit:**

```text
feat(oracle): add dual-source auction price guard
```

### Slice 7: Versioned Index Policy

**Implement:** `IndexPolicy`, `IIndexPolicy`, policy publish/activate behavior,
global policy bounds, and policy-family registry. Allow the pool creator to
publish policies within governance-defined global bounds. Enforce pool asset
count/order and policy normalization against manager configuration.

**Tests:**

- any pool creator can publish for its own pool, but cannot publish for another
  pool or exceed global bounds;
- governance can update global bounds only through the configured timelock;
- immutable-index pools reject later policy versions; managed-index pools accept
  only their recorded creator's delayed versions;
- a published policy hash is the canonical hash of all policy fields and the
  canonical asset order, not a timelock approval marker;
- effective time must be in the future and versions are append-only;
- only one pending version per pool;
- weights sum exactly to BPS, every supported asset has a nonzero weight, and
  array order matches pool order;
- invalid trigger/destination, discount/premium, duration, and turnover bounds
  revert;
- old policy remains active until the new one is effective;
- activating a policy cannot change manager reserves or share supply.

**Complete when:** fuzz tests prove all active policies are normalized and all
policy versions remain immutable after publication.

**Commit:**

```text
feat(policy): add permissionless bounded index policy versions
```

### Slice 8: Rebalance Plan Lifecycle

**Implement:** `AuctionRebalance.startPlan`, plan state, snapshot storage,
drift computation, snapshot target raw amounts and snapshot supply, cadence checks, per-asset caps,
plan turnover caps, config-version pinning, expiry, and guardian cancellation.
Configure the manager's
auction authority once in deployment fixtures.

**Tests:**

- plan creation requires bootstrapped pool, an active creator policy, no existing plan,
  valid dual-source data, and calendar or drift eligibility;
- calculated actual weights, scaled target amounts, surplus/deficit, and turnover match
  independently calculated test values;
- `destination < trigger`, min interval, plan expiry, per-plan turnover, and the
  derived maximum turnover rate are enforced;
- a plan cannot be overwritten or widened;
- guardian can cancel but cannot alter target, reference, or limits;
- plan creation cannot move assets, reserves, or share supply;
- disabling an asset, changing its oracle configuration, changing a policy
  family, or tightening a relevant global bound invalidates active plans and
  permits safe cancellation; redemption remains available.

**Complete when:** fuzz tests prove every stored plan respects its policy limits
and every no-trade failure preserves prior state exactly.

**Commit:**

```text
feat(rebalance): add bounded policy plan lifecycle
```

### Slice 9: Auction Opening and Quote Math

**Implement:** auction selection, current surplus/deficit lot calculation,
linear price curve, and public `openAuction`. Store a single live auction per
pool and reject asset pairs that are not current surplus-to-deficit pairs.

**Tests:**

- only an active unexpired plan opens auctions;
- opening computes `Pstart`, `Pend`, and expiry from immutable plan bounds;
- wrong assets, no surplus/deficit, zero lot, concurrent auction, or expired
  plan reverts;
- redemption after opening changes subsequent available lot but does not change
  the frozen price curve or let lot exceed remaining reserves;
- auction expiration returns the plan to a safe state and never changes
  reserves.
- an ended auction must be explicitly expired before another plan can start;
  an expired plan must be permissionlessly invalidated before a new plan or
  full redemption, so stale plan/auction state cannot be overwritten.

**Complete when:** fuzz tests prove quote monotonicity and lot never exceeds
current surplus, deficit, plan turnover, or actual manager balance.

**Commit:**

```text
feat(auction): add bounded auction creation and quoting
```

### Slice 10: Direct Bids and Atomic Settlement

**Implement:** `bid` and manager `settleAuctionBid`. The bid submits sell
amount and maximum buy payment. Auction code calculates the actual current
payment. Manager receives buy asset from bidder and delivers sell asset in the
same call; it updates pool and aggregate reserves atomically.

**Tests:**

- full and partial fill transfer exact native-token amounts and update both
  reserves correctly;
- a bid below current price, beyond lot, beyond `maxBuyAmount`, after expiry,
  or during unsafe oracle state reverts;
- a fill cannot cross target surplus/deficit or plan turnover cap;
- manager rejects direct calls to settlement from every address except the
  configured auction contract;
- transfer failure rolls back auction, plan, reserve, and token state;
- repeated bids cannot take more than frozen limits;
- a reentrancy-capable mock cannot reenter bid, issue, redeem, or settlement.
- configuration-version changes are permissionlessly invalidatable, while only
  the guardian may unconditionally cancel a plan during a transient oracle failure.

**Invariant harness:** random issue, redeem, plan, open, bid, cancel, and
expire actions with changing mock prices. Assert every invariant in
`ARCHITECTURE_V2.md` Section 8 after each call.

**Complete when:** full V2 suite and the auction invariant suite pass with at
least 2,000 runs. This is the first feature-complete Phase-1 fund release.

**Commit:**

```text
feat(auction): settle direct bids against manager reserves
```

### Slice 11: Operational Controls, Events, and Reporting

**Implement:** guardian pause for issue, plan, open, and bid; mandatory event
set; view methods for reserves, policy state, plan, auction quote, and
execution metrics. Redemption is deliberately not pausable.

**Tests:**

- guardian can pause allowed paths; only the timelock can unpause;
- paused paths revert before token transfers;
- redeem works in every pause and auction state;
- events encode pool ID, policy/plan/auction nonce, reference price, fill,
  turnover, and cancellation reason;
- `quoteBid(poolId, auctionNonce, sellAmount)` repeats every executable guard and
  returns the exact payment for the same block state; lower-level price and
  capacity views are diagnostic only.

**Complete when:** an event-indexing fixture reconstructs the current plan and
auction state from emitted events, then matches onchain views.

**Commit:**

```text
feat(ops): add guardian controls and auction observability
```

### Slice 12: Router

**Implement:** `DemeterBasketRouter` direct in-kind wrappers. It pulls the exact
basket from the user, approves only the Manager for exact amounts, clears every
allowance, and never touches a DEX. A single-asset adapter is a later slice that
requires its own review.

**Tests:**

- router in-kind issue/redeem is accounting-equivalent to direct manager calls;
- user min-in/min-out protects the user;
- failed calls atomically revert without manager asset movement;
- router finishes with zero balances and no manager token allowance;
- no route can call `settleAuctionBid` or alter auction state.

**Complete when:** manager invariants remain true under combined router and
direct-user invariant actions.

**Commit:**

```text
feat(router): add user-owned basket routing
```

### Slice 13: Fork, Deployment, and Release Gate

**Implement:** deployment scripts, per-network configuration, documented
bootstrap and policy publication, and fork tests for every production asset.
Run static analysis and an independent review before an AUM-bearing deployment.

**Tests and evidence:**

- fork reads every production Chainlink feed and configured V3 TWAP pool;
- fork verifies quote direction, decimal normalization, and configured windows;
- local deployment creates, bootstraps, issues, redeems, plans, opens, and
  partially fills an auction;
- deployment scripts assert both one-time Manager authorities, immutable links,
  and timelock/guardian ownership;
- `forge test -vvv`, `forge build --sizes`, and the selected static-analysis
  tool pass without unresolved high-severity findings;
- `AuctionRebalance` runtime bytecode remains at or below 23,500 bytes and all
  other V2 contracts remain inside their checked size budgets;
- simulation report covers partial fill, no fill, price jump, stale feed, and
  AUM-scaled lot stress scenarios.

**Complete when:** a written release checklist is signed off, a security audit
has no unresolved critical/high issue, and operations enforce a documented
conservative first-pool AUM soft cap with monitoring. This cap is an operational
launch control, not a claim-path hard invariant; a hard onchain cap requires a
separate design decision.

**Commit:**

```text
chore(release): add V2 deployment and release-gate checks
```

## 6. Milestone Gates

| Milestone | Required slices | Merge gate |
| --- | --- | --- |
| M1: Claim safety | 0-5 | Full unit, fuzz, and proportional invariant suite passes |
| M2: Price safety | 6-8 | Oracle failure and immutable-policy tests pass |
| M3: Auction safety | 9-11 | Auction invariant suite passes; redemption works in every auction state |
| M4: User and operational readiness | 12-13 | Fork, deployment, static analysis, and audit gates pass |

An AI agent must stop and request a design decision rather than improvise when
it reaches any of these unresolved choices: a new asset class, a new oracle
source, multi-hop TWAP, constituent migration, a DEX adapter, a solver callback,
fees, or yield deployment. Each changes the security boundary and requires a
new architecture decision and test plan.
