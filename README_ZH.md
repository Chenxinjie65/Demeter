# Demeter V2

[English](README.md)

Demeter V2 是无需逐池许可的链上指数基金协议。任何人都可以使用全局
`AssetRegistry` 已批准的资产创建基金，治理无需逐个批准池。

## 状态

单例核心、测试、部署脚本和本地发布门禁已经实现。本仓库不代表生产部署授权。
生产发布仍取决于生产链与资产选择、真实预言机和 TWAP fork 测试、治理角色验证、
经济仿真、独立安全审查以及部署 bytecode 核验。

## 架构

- `DemeterManager` 是全部池的单例托管方和储备账本；
- 每个池拥有 creator-bound `poolId` 和独立 ERC-20 `DemeterShare`；
- issue 输入向上取整，redeem 输出按记录储备向下取整，赎回永不暂停；
- `IndexPolicy` 在 Timelock 全局边界内保存延迟、append-only 的 creator 政策；
- `AuctionRebalance` 执行有界公开荷兰拍卖，Manager 不提供公共 AMM swap、任意
  calldata 或通用 DEX allowance；
- Chainlink 提供主要 USD 锚，批准的外部 Uniswap V3 common-quote TWAP 负责交叉验证；
- `DemeterBasketRouter` 只支持用户自有资金的 in-kind issue/redeem。

## 仓库结构

```text
src/            V2 合约、接口、类型和库
test/v2/        单元、集成、fuzz 和 invariant 测试
script/v2/      部署、连接、建池和发布门禁脚本
docs/           架构、政策、运维和发布文档
research/       非生产调仓比较工具
```

旧 V1 Factory/Beacon/Vault 原型仅保留在 Git 历史中。

## 开发

需要支持 Cancun EVM 的 Foundry 和 Git submodule。

```bash
git submodule update --init --recursive
forge build
forge test --match-path 'test/v2/**' --summary
bash script/v2/check-format.sh
bash script/v2/check-contract-sizes.sh
```

完整发布命令和结果要求见[发布检查清单](docs/zh/RELEASE_CHECKLIST_V2_ZH.md)。

## 文档

- [架构](docs/zh/ARCHITECTURE_V2_ZH.md)
- [实施计划](docs/zh/IMPLEMENTATION_PLAN_V2_ZH.md)
- [调仓白皮书](docs/zh/REBALANCING_WHITEPAPER_ZH.md)
- [架构决策](docs/zh/DECISIONS_ZH.md)
- [路线图](docs/zh/ROADMAP_V2_ZH.md)
- [发布检查清单](docs/zh/RELEASE_CHECKLIST_V2_ZH.md)
- [发布证据](docs/zh/RELEASE_EVIDENCE_V2_ZH.md)
- [静态分析分类](docs/zh/STATIC_ANALYSIS_V2_ZH.md)
- [事故处置手册](docs/zh/INCIDENT_RUNBOOK_V2_ZH.md)
- [安全政策](SECURITY.md)
- [贡献指南](CONTRIBUTING.md)

英文规范是实现权威，中文镜像位于 [`docs/zh`](docs/zh/)。

## 许可证

Demeter 自有代码使用 [MIT License](LICENSE)。派生自 Uniswap 的数学文件保留其
GPL 许可证头，第三方依赖遵循各自的上游许可证。
