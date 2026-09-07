# Demeter V2 Roadmap

[中文](zh/ROADMAP_V2_ZH.md)

> Status: Implementation sequence for the auction-based index-fund design.
>

> Detailed per-contract, per-test, and per-commit work is defined in
> `IMPLEMENTATION_PLAN_V2.md`.

## 1. Delivery Principle

V2 is the canonical working-tree implementation. The former Factory,
BeaconProxy, and vault prototype is retained only in Git history and is not
part of the build or test surface.

The delivery order follows fund safety, not feature breadth:

```
pro-rata claims -> reserve accounting -> policy bounds -> auction settlement
-> optional UX -> optional solver integration
```

No direct DEX execution, yield strategy, generic callback, or generalized hook
is introduced before the fund can prove reserve-proportional redemption and a
bounded auction under fuzzing.

## 2. Keep, Rewrite, and Defer

### 2.1 Deferred from the canonical core

- weighted AMM pricing and public pool swaps;
- passive trajectory and dynamic fee modules;
- arbitrary DEX router execution;
- Aave or any external yield integration;
- generic hooks, flash callbacks, and solver callbacks;
- cross-chain pools and manager upgradeability.

## 3. Delivery Phases

## Phase 0: Freeze Types, Identity, and Global Admission

Build the V2 types/interfaces, creator-bound `poolId`, full-precision math, and
`AssetRegistry` before any permissionless pool can be created. Registry-wide
common-quote TWAP configuration and immutable token decimals are prerequisites,
not a later dependency.

Exit criteria:

- English and Chinese specifications agree on the V2 invariants;
- asset order is canonical and `poolId` includes the creator;
- only the timelock changes enabled assets and global bounds;
- math fuzzing proves issue ceiling, redeem floor, and bounded auction curves.

## Phase 1: Singleton Custody and Proportional Claims

Build `DemeterManager`, per-pool `DemeterShare`, permissionless pool creation,
committed bootstrap, terminal close, and proportional issue/redeem. Pools use
only already-enabled assets and require no DAO transaction per pool.

Exit criteria:

- bootstrap, Manager reserve, aggregate reserve, and token balances agree;
- issue/redeem preserve pro-rata claims under stateful invariants;
- donations never become recorded reserves;
- disabled assets block issue but never recorded-reserve redemption;
- full redemption closes the pool when no plan is active.

## Phase 2: Oracle and Versioned Policy

Build the common-quote Uniswap V3 TWAP adapter, Chainlink/sequencer validation,
`OracleGuard`, policy families, and creator-published delayed policy versions.
`IMMUTABLE_INDEX` accepts one policy; `MANAGED_INDEX` may append creator
versions within current global bounds.

Exit criteria:

- one invalid price source fails closed without affecting redemption;
- an `X/Y` quote uses two asset/common-quote observations;
- stale pending policies are cleanly cancellable;
- global changes invalidate plans without unnecessarily destroying a still
  compliant active immutable policy.

## Phase 3: Bounded Plans and Dutch Auctions

Build plan snapshots, uniformly scaled target raw amounts, per-plan turnover
budgets, one live surplus-to-deficit auction, repeated partial fills, and atomic
Manager settlement. Each bid recomputes capacity from current reserves, live
supply, snapshot target ratio, remaining deficit, and remaining turnover.

Exit criteria:

- no fill exceeds live surplus, deficit, frozen lot, or turnover budget;
- the curve never crosses its maximum discount;
- opening and bidding repeat dual-source oracle checks;
- redemption during an auction safely shrinks the live lot;
- configuration changes are publicly invalidatable; transient oracle failures
  block trading and allow guardian cancellation;
- auction lifecycle invariants pass under randomized state sequences.

## Phase 4: In-Kind Router and Operations

Build `DemeterBasketRouter`, guardian pause controls, events, quotes, and
operational views. The router handles only caller-owned proportional baskets,
uses exact temporary Manager approvals, and contains no DEX or generic call.

Exit criteria:

- router and direct Manager flows are accounting-equivalent;
- router balances and Manager allowances finish at zero;
- pause blocks issue/plan/open/bid but never redemption;
- event and view data are sufficient to reconstruct plan and auction state.

## Phase 5: Deployment and Release Gate

Build immutable-core deployment scripts, Timelock schedule/execute wiring,
contract-size budgets, stateful release invariants, fork checks for the chosen
production assets, and incident/recovery documentation.

Exit criteria:

- local end-to-end create/bootstrap/issue/redeem/plan/open/bid passes;
- production feed/pool direction and decimals pass fork tests;
- no unresolved critical/high audit issue remains;
- operations enforce a documented conservative first-pool AUM soft cap; an
  onchain hard cap is outside this release until separately designed and tested.

## Phase 6: Optional Solver or Single-Asset Adapter

This phase is intentionally outside the first release. Each external venue
adapter must use user/bidder-owned funds, preserve direct-bid limits, be
individually allowlisted and audited, and remain unable to block direct in-kind
redemption.

## 4. Test Requirements

Mandatory categories:

1. Unit tests for every issue, redeem, policy, and auction primitive.
2. Fuzz tests for reserve proportionality, rounding, and aggregate coverage.
3. Fuzz tests for auction price, lot sizing, partial fills, expiry, and
   cancellation.
4. Invariant tests that run issue, redeem, bid, cancel, and pause sequences.
5. Oracle failure-mode tests for stale, divergent, reverted, and sequencer-down
   sources.
6. Token-behavior tests covering false returns, non-standard decimals, and each
   rejected token class.
7. Fork tests for approved Chainlink feeds and approved TWAP venues before any
   mainnet deployment.

## 5. Research and Rollout Requirements

The existing simulator is historical research, not execution evidence. Before
the first production pool it must model:

- intraday price paths and auction fill latency;
- partial and failed fills;
- auction price bands and oracle invalidation;
- gas, DEX hedge cost, and bidder competition assumptions;
- AUM-scaled lot limits and asset-specific liquidity limits.

Production rollout begins with an operational small AUM soft cap, few highly liquid assets, and
one auction at a time. Increasing the cap requires observed fill-quality and
price-impact evidence, not only a favorable backtest.

## 6. Current Execution Source

Per-slice completion criteria, exact test commands, and commit boundaries live
only in `IMPLEMENTATION_PLAN_V2.md`. Release status and unresolved external
requirements live in `RELEASE_CHECKLIST_V2.md`; this roadmap does not carry a
moving "next task" marker.
