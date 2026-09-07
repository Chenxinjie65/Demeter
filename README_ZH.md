# Demeter

[English](README.md)

本仓库工作树仅包含规范的 Demeter V2 单例实现。旧 `Factory + BeaconProxy +
per-vault` 原型仅保留在 Git 历史中，供需要时追溯；所有后续开发都在 V2 上进行。

## 当前方向

Demeter V2 是链上指数基金，而不是以全部基金储备提供公开交易的 AMM：

- 单例 `DemeterManager` 托管所有池的基础资产；
- 每个 `poolId` 对应一个可转让 ERC-20 基金份额；
- 申购和赎回严格按实际记录储备比例执行；
- 经时间锁生效的指数政策版本与漂移区间决定何时调仓；
- 通过有界公开荷兰拍卖完成调仓；
- Chainlink 是主价格锚，外部 DEX TWAP 负责交叉验证；
- DEX 与 solver 是竞拍者的流动性来源，Manager 不持有任意路由授权。
- 任何人都可以从协议批准的资产集合创建自己的指数基金，无需 DAO 逐池批准。
- `DemeterBasketRouter` 只提供无 DEX、无通用调用的 in-kind 用户流程。

## 正式文档

- [V2 架构](docs/zh/ARCHITECTURE_V2_ZH.md)
- [V2 路线图](docs/zh/ROADMAP_V2_ZH.md)
- [V2 实施计划](docs/zh/IMPLEMENTATION_PLAN_V2_ZH.md)
- [调仓白皮书](docs/zh/REBALANCING_WHITEPAPER_ZH.md)
- [架构决策记录](docs/zh/DECISIONS_ZH.md)
- [AI 执行提示词](docs/zh/AI_EXECUTION_PROMPT_V2_ZH.md)
- [V2 发布检查清单](docs/zh/RELEASE_CHECKLIST_V2_ZH.md)
- [V2 静态分析分类](docs/zh/STATIC_ANALYSIS_V2_ZH.md)
- [V2 事故处理手册](docs/zh/INCIDENT_RUNBOOK_V2_ZH.md)
- [V2 发布证据](docs/zh/RELEASE_EVIDENCE_V2_ZH.md)
- [Git 提交迁移](COMMIT_MIGRATION.md)

英文原文仍是实现与安全审计的权威版本。

## 工作规则

实施前必须先阅读架构、白皮书和实施计划。Manager 不得提供公开 AMM
`swap` 路径，也不得执行任意 DEX calldata。
