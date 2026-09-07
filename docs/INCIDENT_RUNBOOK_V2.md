# Demeter V2 Incident Runbook

[中文](zh/INCIDENT_RUNBOOK_V2_ZH.md)

> Status: Operational prerequisite for an AUM-bearing deployment.

## 1. Safety Priorities

1. Preserve proportional redemption and Manager reserve accounting.
2. Stop new issuance and rebalance execution when price or token safety is
   uncertain.
3. Preserve evidence before changing configuration.
4. Use the Timelock for recovery changes; the Guardian may only pause and
   cancel active plans.

No incident response may add an ad hoc DEX call, arbitrary token approval,
proxy upgrade, or redemption pause.

## 2. Roles

| Role | Immediate action | Prohibited action |
| --- | --- | --- |
| Guardian | Pause Auction operations and cancel a Planned/AuctionActive plan | Unpause, change feeds/weights, or move reserves |
| Timelock governance | Disable assets, rotate Guardian, update bounded configuration, unpause | Bypass delay or execute a per-pool discretionary trade |
| Public keeper | Expire ended auctions and invalidate expired/version-stale plans | Cancel a still-valid plan |
| Operator/indexer | Alert, preserve transaction/oracle evidence, publish status | Sign privileged transactions |

## 3. Detection Signals

Page operators on any of the following:

- `manager.tokenBalance(asset) < manager.accountedReserve(asset)`;
- Chainlink stale/incomplete/non-positive rounds or a sequencer outage;
- Chainlink/TWAP divergence or reference movement above configured bounds;
- a plan or auction remaining active past its deadline;
- an unexpected `AssetConfigured`, `GlobalPolicyBoundsUpdated`,
  `PolicyFamilyUpdated`, `GuardianUpdated`, `Paused`, or `Unpaused` event;
- repeated failed fills, realized discount near `Pend`, or unusual bidder
  concentration;
- token proxy/implementation, transfer semantics, decimals, or issuer status
  changing after admission.

## 4. Immediate Response

1. Record chain ID, block number, pool ID, plan/auction nonces, relevant
   transactions, Manager balances/reserves, feed rounds, TWAP observations,
   and current configuration versions.
2. Guardian calls `AuctionRebalance.setPaused(true)`. This blocks issue,
   `startPlan`, `openAuction`, and `bid`; redemption remains available.
3. If a plan is live, Guardian calls `cancelPlan(poolId)`. If it is merely
   expired or version-stale, any keeper uses `expireAuction` or
   `invalidatePlan` instead.
4. For a suspected asset/feed/pool failure, schedule an `AssetRegistry`
   disable or corrected configuration through the Timelock. Do not substitute
   an unreviewed feed or DEX pool under time pressure.
5. Publish which paths are paused, which pools/assets are affected, and that
   in-kind redemption remains available subject to token transfer behavior.

## 5. Scenario Procedures

### Oracle disagreement or sequencer outage

Leave auctions paused until both sources and the sequencer grace period are
healthy. Configuration-valid plans may be Guardian-cancelled; a transient
oracle revert alone must not be used for public invalidation. Start a new plan
only from a fresh dual-source snapshot.

### Token behavior change or depeg

Pause first, then schedule `disableAsset`. Disabling blocks bootstrap, issue,
plan, open, and bid for affected pools but does not block recorded-reserve
redemption. Verify actual Manager balances before telling holders what can be
redeemed. A negative rebase or issuer freeze is an external asset failure and
cannot be repaired by accounting fiction.

### Reserve coverage alarm

Do not unpause. Reproduce balances at the alert block and identify whether the
difference is an unsolicited surplus, transfer/rebase loss, or monitoring
error. A surplus is not assigned to a pool. A deficit requires independent
incident review and a governance-approved migration/remediation plan; never
socialize it by silently editing pool reserves.

### Stuck or unfilled auction

After `endTime`, any keeper calls `expireAuction`. After plan expiry, any keeper
calls `invalidatePlan`. Do not extend the curve, lower `Pend`, or overwrite the
old nonce. Review lot size, external liquidity, and bidder hedge cost before a
new plan.

### Guardian compromise

Timelock schedules `AssetRegistry.setGuardian(newGuardian)`. A compromised
Guardian can pause and cancel plans but cannot unpause, change policy, or move
assets. Review every cancellation and pause event during the exposure window.

### Core defect

The V2 core is not upgradeable. Keep affected execution paths paused, deploy a
new reviewed version, and use a separately specified Timelock migration. Do not
invent a migration call against the immutable Manager; any migration design
requires a new architecture decision, implementation, tests, and audit.

## 6. Recovery Gate

Timelock may unpause only after:

- reserve coverage is reconciled for every affected asset;
- configured Chainlink/TWAP/sequencer sources pass fork checks;
- stale plans and auctions are explicitly cleaned up;
- the root cause and exact configuration diff are reviewed;
- monitoring and regression tests cover the incident;
- public status names remaining external risks.

Run the deterministic commands in `RELEASE_CHECKLIST_V2.md` before recovery.
An external security review is required after any code or trust-boundary change.
