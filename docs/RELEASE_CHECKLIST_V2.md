# Demeter V2 Release Checklist

[中文](zh/RELEASE_CHECKLIST_V2_ZH.md)

> Status: Required release gate. Passing local tests is not authorization to
> deploy assets or accept AUM.

## 1. Code And Specification

- [ ] English and Chinese V2 documents describe the same permissionless pool,
  proportional claim, common-quote oracle, policy, auction, and exit semantics.
- [ ] No V2 interface imports a legacy vault, Beacon, AddressProvider, Aave
  adapter, generic router, callback, or flash-accounting path.
- [ ] Every external state-changing function has NatSpec, a custom-error path,
  a focused test, and an identified state owner.
- [ ] An independent security audit has no unresolved critical or high issue.

## 2. Deterministic Local Gates

Run from the repository root:

```bash
bash script/v2/check-format.sh
forge build --sizes
bash script/v2/check-contract-sizes.sh
bash script/v2/check-slither.sh
forge test --match-path 'test/v2/**' -vv
FOUNDRY_PROFILE=release forge test --match-path 'test/v2/invariants/**' -vv
forge test -vvv
git diff --check
```

Required outcomes:

- [ ] all commands exit zero;
- [ ] proportional claims run at least 1,000 invariant sequences;
- [ ] auction lifecycle runs at least 2,000 invariant sequences;
- [ ] arithmetic fuzz cases run at least 10,000 iterations (`FOUNDRY_PROFILE=release`);
- [ ] `AuctionRebalance` runtime bytecode is at most 23,500 bytes;
- [ ] `DemeterManager` runtime bytecode is at most 22,000 bytes and
  `AuctionRebalance` at most 23,500 bytes;
- [ ] no core contract is near the EIP-170 limit without an explicit review;
- [ ] the reviewed compiler settings use via-IR with `optimizer_runs = 80`; any
  production change to this setting reruns the size and gas review;
- [ ] static analysis findings are triaged and no critical/high issue remains.

Warnings originating only from a pinned test dependency must be recorded, not
silently confused with project warnings.

The V1 prototype is intentionally absent from the V2 working tree; historical
commits remain available when legacy behavior must be inspected.

## 3. Governance And Deployment

- [ ] `V2_TIMELOCK` is a deployed `TimelockController`, not an EOA.
- [ ] proposer, executor, cancellation, and admin roles match the approved
  multisig/governance design; no deployment key retains an unintended role.
- [ ] `DeployV2Core.s.sol` output is reproduced from reviewed source and compiler
  settings.
- [ ] `setIndexPolicy` and `setAuctionRebalance` are scheduled and executed as
  one Timelock batch before the first pool.
- [ ] `CreateV2Pool.s.sol` derives the expected creator-bound ID and publishes
  policy v1 with the committed hash.
- [ ] `ActivateAndBootstrapV2Pool.s.sol` runs only after `effectiveAt`, uses the
  recorded bootstrapper, and verifies exact reserves and initial supply.
- [ ] Manager one-time links, Registry roles, Auction immutables, and Router
  Manager address are verified onchain.
- [ ] Source code is verified and deployment bytecode matches local artifacts.
- [ ] Guardian operational keys and an incident communication path are tested.

## 4. Production Asset Gate

This section cannot be signed before the target chain and first asset set are
chosen.

- [ ] every asset is a standard non-rebasing, non-fee, non-callback ERC-20;
- [ ] token decimals, Chainlink feed direction/decimals/heartbeat, and feed
  min/max behavior are reviewed;
- [ ] every non-quote asset has an approved liquid Uniswap V3 pool against the
  one common quote asset;
- [ ] fork tests verify pool token order, TWAP direction, window, observation
  capacity, decimal normalization, and Chainlink/TWAP divergence;
- [ ] L2 deployments verify the correct sequencer uptime feed and grace period;
- [ ] disabling each asset is simulated: issue/plan/open/bid stop and redemption
  of recorded reserves remains available.

## 5. Economic And Operational Gate

- [ ] simulations cover partial fill, zero fill, stale feed, source divergence,
  sequencer outage, reference jump, auction expiry, and config invalidation;
- [ ] three-or-more-asset scenarios prove uniform target scaling and balanced
  sell/buy notional under per-asset caps;
- [ ] auction sizes are tested against observed external liquidity and bidder
  hedge cost, not only historical closing prices;
- [ ] `maxTurnoverBps` and `minPlanInterval` imply an acceptable maximum turnover
  rate for the first pool;
- [ ] the first pool has a conservative AUM cap and a documented rule for
  increasing it;
- [ ] monitoring covers reserve coverage, oracle disagreement, plan age,
  unfilled notional, realized discount, and guardian actions;
- [ ] incident drills confirm issue/auction pause, guardian cancellation,
  permissionless stale-plan invalidation, and uninterrupted redemption.

## 6. Current External Blockers

The repository does not define a production chain, approved first asset list,
deployed Timelock, RPC endpoint, or completed independent audit. Therefore the
fork, governance-role, audit, and first-AUM checkboxes remain deliberately open.
They must not be inferred from passing mock tests.
