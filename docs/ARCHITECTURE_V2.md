# Demeter V2 Architecture

[中文](zh/ARCHITECTURE_V2_ZH.md)

> Status: Canonical architecture for the V2 `main` branch.
> Scope: Demeter is an onchain index fund. It is not an AMM whose entire
> treasury is offered as public swap liquidity.

## 1. Product Definition

Demeter packages a published, rules-based index into transferable ERC-20 fund
shares. Each share is a proportional claim on an onchain basket of ERC-20
assets. The protocol has three distinct responsibilities:

1. custody and prove the basket reserves;
2. issue and redeem proportional fund claims without oracle-priced dilution;
3. allow anyone to create a fund from the protocol-approved asset set and
   periodically move its basket toward its published index using bounded,
   competitive auctions.

The fund does not promise alpha. It promises transparent exposure to a stated
methodology, subject to disclosed tracking error and execution costs.

## 2. Decisive Design Choices

### 2.1 Fund custody is singleton, fund shares are per-pool ERC-20s

`DemeterManager` is one non-upgradeable custody and accounting contract. It
holds the underlying tokens for every pool and records reserves by `poolId`.
Each pool has one non-upgradeable `DemeterShare` ERC-20 contract. The share
contract has no custody and may only mint or burn through the manager.

This separates a small shared custody surface from the user-facing transferable
receipt. A per-pool share contract is not a per-pool vault or proxy.

### 2.2 Issuance and redemption are always reserve-proportional

For an initialized pool with reserves `R[i]` and share supply `S`:

```
requiredIn[i] = ceil(R[i] * sharesOut / S)
amountOut[i]  = floor(R[i] * sharesIn  / S)
```

Target weights never determine the assets contributed or received by a normal
user. This preserves every existing holder's claim without relying on an
oracle. Pool creation commits a nonzero seed amount for every asset, an initial
share supply, a share recipient, and a bootstrapper. Only the recorded
bootstrapper may call `bootstrap`: a standard ERC-20 allowance is not bound to
`poolId`, so accepting a relayer would permit cross-pool allowance theft. The
Manager pulls the committed amounts from that same bootstrapper.
The initial policy hash must be published and active before bootstrap. Bootstrap
is exact and atomic.

After bootstrap, a full redemption is allowed only when no plan or auction is
active. It transfers the final pro-rata reserves, marks the pool permanently
closed, and prevents any later issue or rebalance. This explicit terminal state
avoids a zero-supply active pool and division-by-zero paths.

Issue is paused while a rebalance plan or auction is active, so the snapshot
target/supply ratio cannot be diluted by concurrent supply growth. Redemptions remain
available, including while an auction is active; they use current actual
reserves and share supply, so a proportional redemption preserves all ratios.

### 2.3 Rebalancing uses auctions, not a public pool swap function

The canonical execution path is a bounded Dutch auction. A bidder transfers a
deficit asset to the manager and receives a surplus asset at the current auction
price. The manager updates reserves atomically. The bidder may source, hedge,
or net that trade through any DEX or solver, but the fund never exposes a
generic `swap` entry point and never gives arbitrary DEX routers an allowance.

The auction makes the maximum execution concession explicit. An unfilled or
partially filled auction leaves tracking error; it never widens its own price
bound or forces a bad trade.

### 2.4 Oracle safety is dual-source and fail closed

Every non-quote asset must have a validated Chainlink USD feed and an approved
DEX TWAP source against the registry's common quote asset. The common quote
itself has a validated Chainlink USD feed and is the numeraire; it does not need
an additional quote/quote TWAP pool. Thus every auction pair still has two
independent pair prices: the Chainlink ratio and the ratio of the two approved
common-quote TWAP observations (with the quote leg resolving to its Chainlink
price).

Chainlink is the primary value anchor. The DEX TWAP independently cross-checks
the pair price. A new auction can start only when both sources are fresh and
within the pool's configured divergence limit. Each bid checks that the current
dual-source quote remains inside the auction's frozen reference band. A breach
cancels or makes the auction unfillable until a new reference snapshot is made.

The oracle values define protection limits only. They never price normal
issuance or redemption.

### 2.5 Core contracts are not upgradeable

`DemeterManager`, `DemeterShare`, `AuctionRebalance`, `IndexPolicy`, and
`AssetRegistry` are deployed without proxies. The custody and claim surface is
therefore immutable once deployed. A defect is handled by pausing affected
non-redemption paths, deploying a new version, and executing a governed
migration; it is not handled by an implementation upgrade.

Critical inter-contract dependencies are either constructor immutables or, for
the Manager's policy and auction links, one-time writes frozen before the first
pool is created. Asset and oracle risk configuration remains mutable only
through the governance timelock and explicit configuration versioning.

### 2.6 AssetRegistry is a restricted registry, not an AddressProvider

V2 intentionally does not use a generic address registry that can replace any
execution module at runtime. `AssetRegistry` is limited to asset admission,
decimals, Chainlink feeds, external TWAP sources, risk parameters, and
guardian/timelock roles. It cannot redirect manager custody or auction
execution to an arbitrary replacement.

Every asset configuration update increments a version. A rebalance plan records
the relevant configuration versions; a subsequent version change invalidates
the plan and its active auction, requiring a new validated reference snapshot.

## 3. Non-Goals For Phase 1

Phase 1 explicitly excludes:

- weighted-invariant pool swaps and gradual AMM weight changes;
- active manager DEX trades and arbitrary calldata execution;
- arbitrary hooks or arbitrary rebalance modules;
- external lending, staking, or yield deployment;
- native ETH custody, fee-on-transfer tokens, rebasing tokens, ERC-777, and
  other callback-capable or balance-changing assets;
- manager upgradeability and cross-chain support.

Pool creation is permissionless within the global asset and parameter safety
policy. Permissionless does not mean unrestricted arbitrary-token deployment:
every constituent must already be enabled in `AssetRegistry`, and every pool
must satisfy the same protocol-wide limits.

General settlement `lock` entry points, callbacks, and EIP-1153 delta accounting
are deferred execution tools. They are not part of the Phase-1 fund accounting
path. This does not prohibit the standard transient reentrancy mutex described
in Section 4.3. A future solver adapter may use broader primitives only behind
a strictly reviewed interface without changing the fund's issuance,
redemption, or auction invariants.

## 4. Canonical Contract Shape

```
Governance Timelock
        |
        +--> AssetRegistry --------> Chainlink feeds / DEX TWAP sources
        |
        +--> IndexPolicy ----------> published weights and rebalance bounds
        |
        +--> DemeterManager <------> DemeterShare(poolId)
                 |  ^
                 |  | proportional issue / redeem
                 v  |
          AuctionRebalance
                 ^
                 |
      bidders, market makers, and solver adapters
                 |
        external DEXs and liquidity venues
```

### 4.1 AssetRegistry

The registry owns asset admission and oracle configuration. For each asset it
stores immutable token decimals, a Chainlink feed, and, for each non-quote
asset, a DEX TWAP observation pool against the registry-wide common quote
asset, plus the TWAP window and risk limits. The common quote stores no
quote/quote pool. Admission is governance-controlled and validates that the asset
is a standard ERC-20 under the protocol's supported-token policy. Runtime exact
balance-delta checks remain necessary because token behavior cannot be proven
completely at admission.

The registry records the timelock and guardian roles. A risk team may prepare
proposals offchain, but every registry write is executed by the timelock; no
separate onchain risk-admin role can move assets or update oracle metadata.
The timelock must be a deployed contract. Protocol hard bounds require a TWAP
window between 5 minutes and 7 days, Chainlink staleness no greater than 7
days, and (when configured) an L2 sequencer grace period between 1 minute and
1 day. Production values must be tighter and feed-specific where appropriate.

### 4.2 State Ownership

Each mutable fact has one owner. Other contracts may read it but must not keep a
second authoritative copy.

| State | Owner | Writers | Reason |
| --- | --- | --- | --- |
| Asset admission, decimals, feeds, TWAP configuration, guardian | `AssetRegistry` | Governance timelock | Separates global risk configuration from custody |
| Pool key, ordered assets, creator, bootstrapper, reserves, aggregate reserves, share token, closed state | `DemeterManager` | Any creator within registry limits; Manager records the result | Makes the custody ledger the sole source of claims |
| Policy versions, active policy, policy families, and global policy bounds | `IndexPolicy` | Pool creator within global bounds; timelock sets only global bounds/family status | Makes methodology permissionless yet bounded |
| Rebalance plans, active auction, used turnover, plan/auction nonces | `AuctionRebalance` | Public calls constrained by policy and oracle checks | Keeps execution state outside the custody ledger |
| ERC-20 supply, balances, and allowances | `DemeterShare` | Manager for mint/burn; holders for transfer/approval | Gives users a standard transferable receipt |

`AuctionRebalance` may ask `DemeterManager` to settle exactly one validated
bid. The manager pulls the bid asset from the bidder, updates reserves, and
sends the sell asset in the same transaction. `AuctionRebalance` never takes
custody and `DemeterManager` never receives arbitrary external call data.

### 4.3 DemeterManager

The manager is the source of truth for:

- immutable pool configuration and asset order;
- `reserve[poolId][asset]` and aggregate accounted balances;
- one registered `DemeterShare` per pool;
- reserve-proportional issue and redeem;
- atomic auction settlement.

The manager does not call DEX routers, approve arbitrary spenders, quote a
weighted invariant, or allow direct pool-to-pool netting. Actual ERC-20
balances are never used as a reserve oracle: unsolicited transfers are excess
balances and cannot change a pool claim.

For every asset, manager balances must cover the sum of all pool reserves. V2
Phase 1 has no protocol-fee reserve or other outgoing accounting category. This
global invariant is checked on every token-moving path.

All Manager asset operations share one transient reentrancy guard. While that
guard is entered, `isPoolActive` deliberately returns false and
`isOperationActive` returns true. The fixed Policy and Auction modules use this
signal to reject policy activation and lifecycle mutations from token
callbacks. Outside the executing transaction, pool activity is unchanged.

### 4.4 DemeterShare

`DemeterShare` is a minimal ERC-20 claim token. It implements ordinary
transfers and allowances. Only the manager may mint and burn. Pool shares are
transferable from the first production release; no bespoke manager-only receipt
format is exposed to users.

### 4.5 IndexPolicy

`IndexPolicy` holds versioned methodology state, not custody. A policy version
contains:

- the immutable asset universe for its pool;
- normalized target weights;
- an effective epoch and a creator-committed policy hash;
- calendar cadence, drift trigger, and destination threshold;
- maximum turnover and maximum per-asset adjustment;
- auction duration, start premium, maximum discount, and oracle bands.

The pool creator publishes the initial policy and may publish later policy
versions only if the pool was created as `MANAGED_INDEX` and the new version
stays inside the protocol-wide limits. Policy publication is permissionless but
delayed by `effectiveAt`, append-only, and hash-committed. Cancelling a pending
initial version does not delete or reuse version 1; the pool remains
unbootstrappable until it expires. An immutable index
accepts exactly one active policy. Governance sets global bounds and may disable
a policy family for future publications; it does not approve each pool.
The guardian may freeze new issuance and rebalance actions, but cannot write
discretionary weights or activate a replacement policy.

Policy timing also has immutable protocol floors and ceilings: policy delay
and minimum plan interval are each at least 5 minutes, plan duration is at most
30 days, and auction duration is at least 5 minutes. Governance may choose
stricter bounds but cannot weaken these floors.

### 4.6 AuctionRebalance

`AuctionRebalance` is a manager-authorized execution module, not an independent
custodian. It opens and settles a single bounded auction at a time for each
pool. The first version supports direct ERC-20 bids only:

1. the bidder supplies `buyToken` to the manager;
2. the manager sends `sellToken` to the bidder;
3. reserves and remaining surplus/deficit are updated atomically.

There is no bidder callback in Phase 1. A future solver fill may be added only
as a separately audited adapter that can prove at least the same `minBuy` and
reserve constraints as a direct bid.

### 4.7 Oracle Components

`OracleGuard` is a library used by `AuctionRebalance`; it has no state. It
reads immutable decimal metadata and oracle configuration from `AssetRegistry`.
`UniswapV3TwapOracle` is a stateless adapter which obtains a quote from an
approved Uniswap V3 pool using `observe()`. It cannot custody assets, accept
arbitrary pools, or write configuration. The registry supplies the allowed pool,
quote asset, and TWAP window.

The first implementation stores one approved asset/common-quote TWAP pool per
asset. An `X/Y` market quote is derived from the two independently validated
common-quote observations. Arbitrary direct `X/Y` mappings, multi-hop TWAP
construction, fallback sources, and non-Uniswap adapters are deferred.

### 4.8 DemeterBasketRouter

`DemeterBasketRouter` is an optional in-kind UX layer. It refunds any unsolicited
router balance to the current caller at the start of the call, pulls the exact
proportional basket, grants only exact transient Manager allowances, calls issue,
and clears every allowance. This dust policy prevents a third party from
permanently blocking the stateless router with a donation. Redemption sends
assets directly from the Manager to the user's receiver. Single-asset DEX
routing is not included in Phase 1 and requires a separately reviewed adapter.

## 5. Pool Identity And State

`poolId` is stable even when the index publishes new weights. It is derived
from immutable data only:

```
poolId = keccak256(
    chainId,
    address(manager),
    creator,
    orderedAssets,
    policyFamilyId,
    creatorSalt
)
```

Target weights, fee values, oracle parameters, the current policy version, and
the share address are deliberately excluded. Including the creator binds pool
ownership and prevents a public mempool transaction from being copied and
claimed by a frontrunner. The manager derives `poolId` first and deploys the
per-pool share with `CREATE2` using that ID as the salt. Assets are immutable in
Phase 1. A constituent change creates a governed migration to a new pool rather
than mutating an existing pool's asset list.

Each pool stores:

- ordered assets and reserves;
- its share token and total share supply;
- bootstrap commitment and closed state;
- bootstrap expiry and terminal closed state.

Policy and auction versions, lifecycle, and active auction data are read from
their owning contracts; the Manager does not duplicate those states.

## 6. Rebalance Model

### 6.1 Two different events

The protocol distinguishes:

1. **Structural index updates.** The pool creator publishes a new policy version
   at a scheduled epoch. It is delayed until `effectiveAt` and must satisfy the
   global policy bounds. Governance does not approve individual pools.
2. **Drift control.** The existing policy remains unchanged, but actual value
   weights move outside a configured band. A plan may reduce, but need not
   eliminate, the drift.

For price vector `p`, actual weights are:

```
a[i] = reserve[i] * p[i] / sum(reserve[j] * p[j])
drift = 1/2 * sum(abs(a[i] - targetWeight[i]))
```

A drift plan starts only when `drift >= triggerBps` and all cadence and
turnover guards pass. It stops at `destinationBps`, which is strictly inside
the trigger band. This hysteresis prevents repeated small trades.

Phase 1 does not keep a separate rolling-window accumulator. The combination
of `maxTurnoverBps` per plan and `minPlanInterval` gives a deterministic maximum
turnover rate; governance must set both together for the supported chain and
asset set.

### 6.2 Plan creation

After a policy is eligible, anyone may call `startPlan` with fresh oracle
data. `AuctionRebalance` (not the custody Manager) performs the following:

1. validates both price sources for every asset;
2. computes target raw amounts from the current total reference value and
   policy weights;
3. applies one common scaling factor so per-asset and aggregate turnover caps
   cannot produce a non-value-conserving target vector;
4. records a nonce, target raw amounts, the snapshot share supply, reference
   prices, configuration versions, and an expiry.

The plan does not assume it will reach an exact target. A new plan cannot
overwrite an active one. Once its deadline passes, anyone must call
`invalidatePlan` to move it to `Expired` before a new plan or full redemption;
this explicit transition prevents stale auction state from being rebound to a
new plan nonce.

### 6.3 Auction lifecycle

```
Idle -> Planned -> AuctionActive -> Planned -> Settled
                  \-> Expired / Cancelled -> Idle
```

- `Idle`: no eligible plan.
- `Planned`: target and reference snapshot are fixed; anyone may open a valid
  surplus-to-deficit auction.
- `AuctionActive`: one pair is live. Bids may partially fill it.
- `Settled`: the destination is reached, the turnover budget is exhausted, or
  no raw-unit surplus/deficit pair remains executable.
- `Expired` or `Cancelled`: safe execution was unavailable; the pool retains
  its current composition until a later plan.

An ended auction remains lifecycle-locked until anyone calls `expireAuction`.
An expired plan remains lifecycle-locked until anyone calls `invalidatePlan`.
Both cleanup calls are permissionless, move no assets, and prevent stale state
from being silently overwritten.

`AuctionRebalance` recalculates available lot size for every bid by reading
current Manager reserves and the exact ratio of snapshot target raw amount to
snapshot share supply. A redemption therefore cannot invalidate or overfill an
auction, including for low-decimal assets and very large share supplies.

### 6.4 Auction price and lot constraints

For fund sell asset `X`, fund buy asset `Y`, and frozen reference quote `P0`
denominated in `Y per X`:

```
Pstart = P0 * (1 + startPremium)
Pend   = P0 * (1 - maxDiscount)
P(t)   = linearInterpolate(Pstart, Pend, elapsed / duration)
```

The first bidder receives the current price, not its submitted maximum. Each
bid declares a maximum payment and is rejected if it cannot satisfy the current
price. The fill is capped by both the remaining `X` surplus and `Y` deficit.

`maxDiscount`, duration, lot limits, and a plan-wide turnover budget are
immutable for the plan. No execution path may lower `Pend`, extend the plan,
or increase the turnover budget after plan creation.

### 6.5 DEX and solver participation

DEX trading is supported outside the custody boundary:

- any market maker can hedge a direct bid through a DEX before or after bidding;
- a solver can later submit a constrained fill adapter once it is audited and
  governance-enabled;
- a future batch-auction integration may net several legs offchain, but must
  settle each accepted result under the same onchain auction limits.

The fund itself has no arbitrary DEX execution permission. This protects the
manager from router upgrades, malicious calldata, and approval abuse.

### 6.6 Oracle guard

At plan creation and before every bid, `OracleGuard` requires:

- valid, fresh Chainlink prices and a healthy sequencer where applicable;
- valid DEX TWAP quotes over the configured window;
- inter-source divergence within `maxOracleDeviationBps`;
- current pair price within the active plan's frozen reference band.

When any condition fails, new auctions and bids revert. Anyone may invalidate a
plan after a pinned configuration version changes. Transient price-source
failure does not by itself authorize public cancellation: the guardian may
cancel the auction, while redemption remains available throughout.

`quoteBid(poolId, auctionNonce, sellAmount)` repeats the executable pause,
lifecycle, configuration, oracle, capacity, expiry, price, and turnover checks
and returns the exact `buyAmount` for a same-block bid. Receiver-zero and
caller-specific `maxBuyAmount` checks remain transaction-specific. The lower-
level `currentPrice` and `liveAuctionCapacity` views are diagnostic only.

Disabling an asset blocks issue, plan creation, auction opening, and bids for
affected pools. It never blocks proportional redemption of recorded reserves.

## 7. Permissions

| Role | Authority | Explicitly cannot do |
| --- | --- | --- |
| Governance timelock | Approve assets, set global safety bounds, and approve future solver adapters | Approve or reject individual pools, move reserves, or bypass auction limits |
| Guardian | Pause issuance and rebalance; cancel Planned or AuctionActive plans | Unpause, change weights, sell assets, block redemption |
| Risk admin | Propose registry and oracle updates through governance process | Execute trades or set discretionary prices |
| Pool creator | Create a pool from enabled assets, seed it, and publish bounded policy versions for its pool | Add unapproved assets, exceed global limits, move reserves, or bypass policy delays |
| Public caller | Start eligible plans, open valid auctions, bid, expire auctions, and invalidate stale plans | Alter plan bounds, cancel a safe auction, or change target weights |
| Share holder | Transfer shares, issue proportionally, redeem proportionally | Influence auction price or pool reserves except through normal flows |

## 8. Security Invariants

1. Every share is redeemable for its exact pro-rata claim on current recorded
   reserves, subject only to standard token-transfer failure. A full redemption
   atomically closes the pool and cannot leave an active zero-supply pool.
2. Target weights and oracle values never determine normal issue or redeem
   amounts.
3. The manager's recorded aggregate reserve for an asset never exceeds its
   actual token balance.
4. No token leaves the manager except through a proportional redemption or a
   validated auction fill.
5. An auction cannot sell more than its current surplus or buy more than its
   current deficit.
6. An auction price cannot be worse for the fund than its frozen `Pend` bound.
7. Oracle disagreement, staleness, or an unsafe price move blocks execution.
8. A partial fill can only improve the active plan's measured deficit/surplus;
   it cannot create an unaccounted liability.
9. A pause never prevents pro-rata redemption.
10. No arbitrary contract receives manager asset approval or callback control.

## 9. Phase-1 Contract Inventory

- `src/core/DemeterManager.sol`
- `src/core/AssetRegistry.sol`
- `src/core/IndexPolicy.sol`
- `src/core/AuctionRebalance.sol`
- `src/core/DemeterShare.sol`
- `src/core/DemeterBasketRouter.sol`
- `src/oracle/UniswapV3TwapOracle.sol`
- `src/interfaces/IDemeterManager.sol`
- `src/interfaces/IIndexPolicy.sol`
- `src/interfaces/IAuctionRebalance.sol`
- `src/interfaces/IAssetRegistry.sol`
- `src/interfaces/ITwapOracle.sol`
- `src/interfaces/IDemeterShare.sol`
- `src/libraries/PoolId.sol`
- `src/libraries/ProportionalMath.sol`
- `src/libraries/AuctionMath.sol`
- `src/libraries/OracleGuard.sol`
- `src/libraries/V2Errors.sol`

`DemeterVault`, `DemeterFactory`, the legacy `DemeterRouter`, `VaultMath`,
the Aave adapter, the standalone circuit breaker, weighted AMM math, and
passive trajectory logic are legacy references only.

## 10. Implementation Rule

No production core contract is written until the following are frozen in tests
and documentation:

1. reserve-proportional issuance and redemption equations;
2. supported-token policy and aggregate reserve accounting;
3. policy-version and plan state layouts;
4. auction lot, price, expiry, and cancellation semantics;
5. dual-source oracle validation and stale-price behavior;
6. role permissions and emergency redemption behavior;
7. the invariants in Section 8.
