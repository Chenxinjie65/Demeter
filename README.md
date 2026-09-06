# Demeter

[中文版](README_ZH.md)

This repository now contains two realities:

- the existing `Factory + BeaconProxy + per-vault` implementation, which is treated as legacy prototype code,
- the `redesign_v2_singleton` rewrite effort, which is the canonical direction for new development.

## Current Direction

V2 is being redesigned around:

- a singleton `DemeterManager`,
- `bytes32 poolId` multi-pool reserve accounting,
- transferable per-pool ERC-20 fund shares,
- reserve-proportional issue and redemption,
- timelocked index-policy versions and drift bands,
- bounded public Dutch auctions for rebalancing,
- Chainlink primary anchors with external DEX TWAP cross-checks,
- DEX and solver liquidity used by bidders outside the manager custody boundary.
- permissionless creation of index funds from the protocol-approved asset set.
- a direct in-kind `DemeterBasketRouter` with no DEX or generic-call surface.

## Canonical Documents

- [V2 Architecture](docs/ARCHITECTURE_V2.md)
- [V2 Roadmap](docs/ROADMAP_V2.md)
- [V2 Implementation Plan](docs/IMPLEMENTATION_PLAN_V2.md)
- [Rebalancing Whitepaper](docs/REBALANCING_WHITEPAPER.md)
- [Architecture Decision Log](docs/DECISIONS.md)
- [AI Execution Prompt](docs/AI_EXECUTION_PROMPT_V2.md)
- [V2 Release Checklist](docs/RELEASE_CHECKLIST_V2.md)
- [V2 Static Analysis Triage](docs/STATIC_ANALYSIS_V2.md)
- [V2 Incident Runbook](docs/INCIDENT_RUNBOOK_V2.md)
- [V2 Release Evidence](docs/RELEASE_EVIDENCE_V2.md)

Chinese mirrors: [architecture](docs/zh/ARCHITECTURE_V2_ZH.md),
[roadmap](docs/zh/ROADMAP_V2_ZH.md), [implementation plan](docs/zh/IMPLEMENTATION_PLAN_V2_ZH.md),
[rebalancing whitepaper](docs/zh/REBALANCING_WHITEPAPER_ZH.md), and
[decision log](docs/zh/DECISIONS_ZH.md). The [AI prompt](docs/zh/AI_EXECUTION_PROMPT_V2_ZH.md)
and [release checklist](docs/zh/RELEASE_CHECKLIST_V2_ZH.md) are also mirrored.
Static-analysis triage is mirrored [here](docs/zh/STATIC_ANALYSIS_V2_ZH.md).
The incident runbook is mirrored [here](docs/zh/INCIDENT_RUNBOOK_V2_ZH.md).
Release evidence is mirrored [here](docs/zh/RELEASE_EVIDENCE_V2_ZH.md).

## Working Rule

New core development must follow the V2 documents before contract implementation.
The manager must not expose a public AMM `swap` path or arbitrary DEX execution.
