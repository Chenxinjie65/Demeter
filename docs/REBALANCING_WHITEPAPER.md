# Demeter Rebalancing Whitepaper

[中文](zh/REBALANCING_WHITEPAPER_ZH.md)

> Status: Canonical economic and execution specification for Demeter V2.
>
> Product: an onchain index fund, not a public AMM liquidity pool.

## 1. Purpose

This document defines how Demeter maintains a published index allocation without
turning its entire basket into an AMM inventory. The design objective is not to
maximize short-term return. It is to control index tracking error while making
execution cost, authority, and failure modes explicit.

Demeter selects an **Epoch-Banded Auction Rebalance** model:

1. each pool creator publishes transparent target-weight policy versions inside
   protocol-wide governance bounds;
2. calendar events and drift bands decide when a plan is eligible;
3. a fresh dual-source reference snapshot determines bounded auction limits;
4. public bidders compete to move the basket from surplus assets to deficit
   assets;
5. partial or failed execution leaves disclosed tracking error instead of
   creating unlimited price concessions.

## 2. Fund Accounting Baseline

For `n` assets:

- `q[i]`: units of asset `i` in recorded fund reserves;
- `p[i]`: validated reference price of asset `i`;
- `V = sum(q[i] * p[i])`: reference portfolio value;
- `N`: total fund-share supply;
- `w[i]`: published target value weight, with `sum(w[i]) = 1`;
- `a[i] = q[i] * p[i] / V`: actual value weight.

The drift metric is total variation distance:

```
D(a, w) = 1/2 * sum(abs(a[i] - w[i]))
```

The no-rebalance, buy-and-hold portfolio is the mandatory benchmark. A
rebalance mechanism is acceptable only when its improved exposure control
justifies its execution cost and residual risks.

Normal issuance and redemption do not use `p` or `w`:

```
issue:  in[i]  = ceil(q[i] * sharesOut / N)
redeem: out[i] = floor(q[i] * sharesIn  / N)
```

This distinction is fundamental. Oracle-priced single-asset issuance is a
separate routing product, not a fund-core accounting operation.

## 3. Why the AMM Design Is Rejected

A weighted AMM changes its quoted marginal price when its weights change.
Arbitrageurs then trade the pool toward external prices. That mechanism is
useful for a market-making pool or a liquidity bootstrapping pool, but it means
fund holders are the counterparty to the adjustment.

For a fund, the resulting cost is not merely a visible swap fee. It includes
adverse selection and invariant repricing loss. The previous Demeter research
model labels this cost as implicit loss; its historical outputs show that
passive-swap and passive-damped outcomes are highly parameter- and
market-regime-sensitive. Those results are evidence to reject the model as a
default, not evidence to tune it for production.

Therefore Demeter does not use:

- a public `swap()` against fund reserves;
- effective weights that change the fund's internal trading curve;
- directional swap fees as the primary rebalance incentive;
- a continuous `wPath -> wEffective` migration.

These mechanisms may later be researched as a separate liquidity product. They
are not index-fund execution.

## 4. Historical Execution Patterns

### 4.1 Direct DEX execution

The earliest onchain index systems commonly let a privileged manager trade the
basket through DEX adapters. This converges quickly when liquidity is good, but
the protocol must maintain exchange integrations, approvals, arbitrary call
data controls, and per-trade slippage protection. Execution quality is mostly a
manager and routing assumption.

Use case: an actively managed vault with a trusted or allowlisted executor.

Why Demeter does not use it in Phase 1: the shared custody manager should not
have arbitrary external-call authority.

### 4.2 TWAP-sliced DEX execution

Splitting a large trade reduces instantaneous market impact. It also makes the
future order flow predictable, requires keepers, and exposes every slice to
MEV. It is appropriate for time-critical strategy maintenance, such as leverage
control, but not the default for a passive index fund.

Use case: risk-driven liquidation avoidance where completing the trade is more
important than precise execution cost.

### 4.3 Gradual-weight AMM

Balancer-style gradual weight updates shift a pool price over time and let
traders arbitrage the new path. This is effective price discovery for LBPs and
managed liquidity pools, but it deliberately exposes LP inventory to public
trading.

Use case: liquidity provisioning or token distribution.

Why Demeter rejects it: the product wants tracked portfolio exposure, not
continuous market-making revenue and loss.

### 4.4 Dutch auction

A Dutch auction offers a known amount of a surplus asset for a deficit asset.
The price starts fund-favorable and declines only to a pre-approved worst price.
Any market maker, bot, DEX aggregator, or solver can compete to fill it.

Use case: transparent, infrequent portfolio transitions where partial fills are
acceptable.

Why Demeter selects it: the execution concession is observable and bounded,
the manager does not need DEX approvals, and bidders can source the deepest
liquidity available to them.

### 4.5 Batch-auction solvers and RFQ

Batch solvers can net multiple legs and discover a uniform clearing price. RFQ
can obtain good quotes from professional market makers. Both are useful future
execution sources, but they add external availability, signature, and solver
validation dependencies.

Demeter treats these as future bidders or audited fill adapters, never as an
unconstrained manager authority.

## 5. Trigger Policy

Trigger policy determines *whether* to trade. Auction policy determines *how*
to trade. They must remain separate.

### 5.1 Structural policy epochs

A policy epoch can alter weights only after its per-pool delay. It represents
the pool creator's published index methodology, such as a monthly review or
quarterly reconstitution. The creator can choose the target vector, but cannot
exceed global asset, turnover, auction, or oracle limits set by governance. A
policy update contains the target vector and immutable safety bounds, not
executable prices.

`IMMUTABLE_INDEX` accepts only its initial policy. `MANAGED_INDEX` permits its
recorded creator to publish later delayed versions. Neither mode requires DAO
approval of an individual pool or policy.

### 5.2 Drift bands

Price movement may make the actual basket depart from the same policy. A drift
plan is eligible only when:

```
D(a, w) >= trigger
now >= lastPlan + minInterval
```

Execution stops when the remaining drift is at or below `destination`, where:

```
0 <= destination < trigger
```

The gap is hysteresis. It avoids repeatedly paying to oscillate exactly around
the target. The exact values are pool-specific and must come from liquidity and
historical sensitivity analysis, not universal constants.

### 5.3 Turnover constraints

For target units `qTarget`:

```
T = 1/2 * sum(abs(qTarget[i] - q[i]) * p[i])
```

Every plan applies:

- a maximum per-asset adjustment;
- a maximum plan turnover fraction of `V`;
- a minimum time between plans.

Phase 1 derives its maximum turnover rate from the per-plan cap and minimum
plan interval. It does not maintain a separate rolling-window accumulator.

When a policy requires more turnover than allowed, the plan executes only the
bounded first step. It does not silently change the policy target.

## 6. Epoch-Banded Auction Rebalance

### 6.1 Plan formation

After a policy is eligible, anyone may start a plan. The `AuctionRebalance`
contract (not the custody Manager) obtains a
fresh reference price for every pool asset and calculates:

```
qTarget[i] = V * w[i] / p[i]
surplus[i]  = max(q[i] - qTarget[i], 0)
deficit[i]  = max(qTarget[i] - q[i], 0)
```

The stored plan includes:

- policy version and monotonic nonce;
- target raw amounts and the snapshot share supply; live targets use the exact
  ratio `targetRaw * liveSupply / snapshotSupply` with full-precision `mulDiv`;
- frozen reference prices and reference timestamp;
- expiry, turnover budget, and per-asset adjustment limits;
- oracle divergence and frozen-reference movement bands;
- start premium, maximum discount, and auction duration.

The plan is a risk envelope. It is not a promise that the basket will reach its
exact target.

### 6.2 Auction creation

Anyone may open a valid auction from one current surplus asset `X` to one
current deficit asset `Y`. At most one auction is live for a pool in Phase 1.
The lot is recomputed from live recorded reserves and current share supply, then
capped by the plan's remaining limits.

This intentionally favors a small state machine over parallel execution. A
future batch solver may optimize multi-leg settlement after the single-auction
model is proven.

### 6.3 Price curve

Let `P0` be the frozen dual-source quote in units of `Y per X`. The initial
curve is linear:

```
Pstart = P0 * (1 + startPremiumBps / 10_000)
Pend   = P0 * (1 - maxDiscountBps  / 10_000)
P(t)   = Pstart - (Pstart - Pend) * elapsed / duration
```

The fund sells `X` only when it receives at least `P(t)` units of `Y` per unit
of `X`. A bidder supplies a maximum payment; the bid receives the current
price, never a worse bidder-submitted price. A fill cannot exceed either side's
remaining surplus or deficit.

The curve is immutable once opened. No actor can lower `Pend`, extend its
duration, or increase the lot or plan turnover budget.

### 6.4 Partial fills and expiry

Each fill updates fund reserves atomically and recomputes the remaining lot.
The plan uses live share supply after each proportional redemption; issue is
paused while a plan or auction is active. A full redemption is rejected during
an active plan and otherwise closes the pool permanently, preventing a
zero-supply active plan.
Partial fill is expected behavior. After an auction ends, anyone calls
`expireAuction`; the plan then returns to the planned state while its plan
deadline remains live, or becomes expired otherwise. Once a plan deadline has
passed, anyone calls `invalidatePlan` to release its lifecycle lock. These
explicit cleanup transitions move no assets and prevent stale auction state
from being rebound to a new plan. The fund retains its current allocation and
partial redemption remains available throughout.

There is no forced close at an inferior price. A new plan requires a fresh
dual-source snapshot and the normal cadence rules.

## 7. Oracle Design

### 7.1 Sources and duties

| Source | Duty | Never used for |
| --- | --- | --- |
| Chainlink USD feed | Primary value anchor and asset admission | Direct issue/redeem pricing |
| DEX TWAP | Independent pair-price check and market-dislocation signal | A Demeter-pool self-reference |
| Auction curve | Actual bid price | An unbounded market oracle |

Every non-quote asset needs a Chainlink feed and an approved sufficiently liquid
DEX TWAP source against one common quote asset (for example, USDC). The common
quote has a Chainlink feed but no quote/quote TWAP pool because it is the
numeraire. The DEX source must be external to Demeter. Pair quotes for `X/Y`
are derived from the two common-quote observations, with the quote leg resolved
to its Chainlink value; the pair is still checked against the independent
Chainlink ratio. Arbitrary direct pair pools and multi-hop paths are not
accepted in Phase 1.

### 7.2 Dual-source validation

At plan creation and before every bid, the protocol verifies:

1. Chainlink data is positive, complete, fresh, and sequencer-valid;
2. DEX TWAP observation succeeds over the configured window;
3. the Chainlink-implied and TWAP-implied pair quotes differ by no more than
   `maxOracleDeviationBps`;
4. the current validated quote remains inside the plan's movement band around
   `P0`.

If any condition fails, bids revert. The current plan/auction configuration
version is compared with the Registry and policy versions; a mismatch makes
the plan invalid and anyone may call `invalidatePlan`. A transient oracle
failure blocks opening and bidding but permits unconditional cancellation only
by the guardian. Disabling an asset blocks new issue and all plan/auction
actions for affected pools, but never blocks redemption.
This is intentionally fail closed: preserving a temporary tracking deviation is
better than selling at a stale price.

### 7.3 Why neither source is sufficient alone

Chainlink can be delayed relative to a fast market. A DEX spot quote is readily
manipulated, while a TWAP can lag and depends on pool liquidity. Requiring both
to agree within an explicit range removes neither risk, but turns disagreement
into a safe no-trade condition.

The plan freezes `P0`; it does not move every bid price with the oracle. Moving
the curve continuously would recreate a dynamic market maker with a more opaque
execution path. The current quote is used only to invalidate an unsafe frozen
auction.

The `quoteBid(poolId, auctionNonce, sellAmount)` view repeats the executable
pause, lifecycle, configuration, oracle, capacity, expiry, price, and turnover
checks and returns the exact payment a same-block `bid` would use. The bid's
receiver and caller-specific maximum-payment checks remain transaction-specific;
the lower-level price and capacity views are diagnostic only.

## 8. DEX and Solver Support

The protocol supports DEX liquidity without giving custody to a DEX router:

1. a direct bidder can hedge before or after bidding through any venue;
2. a market maker can aggregate several venues offchain and bid directly;
3. an approved future solver adapter can submit a fill whose onchain result
   satisfies the exact same asset, lot, price, and reserve checks.

The manager never exposes arbitrary calldata or broad approvals. A solver that
is unavailable or faulty cannot block direct bidders or fund redemption.

## 9. Economic Costs and Acceptance Criteria

For every completed fill, report:

```
executionCost = referenceValueSold - referenceValueReceived
fillDiscount  = (P0 - executionPrice) / P0
turnover      = referenceValueSold
```

The protocol should also report time-to-fill, unfilled notional, post-plan
drift, oracle disagreement events, and bidder concentration. Governance must
evaluate these against buy-and-hold and direct-DEX reference simulations.

A pool is not ready to increase its AUM cap unless observed execution stays
inside its approved discount and price-impact budget under realistic lot sizes.
High historical return in a backtest is not sufficient evidence.

## 10. Security and Governance Boundaries

- Governance timelock approves the global asset set and hard execution bounds;
  pool creators publish their own bounded policies without per-pool approval.
- Guardian can pause issuance and rebalance and cancel Planned or AuctionActive plans; it
  cannot unpause, change weights, move reserves, or block redemption.
- The risk admin can propose oracle and admission changes only through the
  governance process.
- Public callers can start eligible plans, open valid auctions, bid, expire
  auctions, and invalidate stale plans, but cannot change bounds or cancel a
  configuration-valid auction.
- Any address can create a pool from enabled assets; only its recorded
  bootstrapper can complete bootstrap. The creator and policy hash are
  permanently visible onchain.
- No semi-trusted launcher may select a more favorable-to-itself price inside a
  governance range in Phase 1.

This is stricter than designs that give an auction launcher price flexibility.
The trade-off is lower operational convenience for a smaller value-leakage and
governance surface.

## 11. Research Agenda

The deterministic V2 comparison now covers policy trigger variants, uniform
plan scaling, opening delay, bounded curve progression, partial and zero fills,
expiry, oracle interruptions, configuration invalidation, hedge cost, gas, and
liquidity-limited execution. It is reproducible through
`research.rebalancing_study.v2_compare`.

Before deployment, research must still add calibrated intraday paths, live
Chainlink and Uniswap observations, pairwise auction ordering, competing bidder
behavior, MEV, chain-specific gas, and AUM-scaled depth for each approved asset.

The selected method is relatively optimal only under the fund's stated
objective: explicit bounded execution cost, open competition, and no arbitrary
manager trading authority. It is not claimed to dominate buy-and-hold or all
execution methods in every market regime.

## 12. References

- [Index Coop, "Introducing Auction Rebalancing"](https://www.indexcoop.com/blog/introducing-auction-rebalancing).
- [Reserve Index Protocol, "Rebalance Lifecycle", release 4.0.0](https://docs.reserve.org/reserve-index/rebalancing/4-0-0).
- [Balancer, "Liquidity Bootstrapping FAQ"](https://balancer.gitbook.io/balancer/smart-contracts/smart-pools/liquidity-bootstrapping-faq).
- [Vanguard, "The Rebalancing Edge: Optimizing Target-Date Fund Rebalancing Through Threshold-Based Strategies"](https://corporate.vanguard.com/content/dam/corp/research/pdf/the_rebalancing_edge_optimizing_target-date-fund-rebalancing-through-threshold-based-strategies.pdf).
