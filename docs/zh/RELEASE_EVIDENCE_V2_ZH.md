# Demeter V2 发布证据

[English](../RELEASE_EVIDENCE_V2.md)

> 证据日期：2026-09-06
>
> 本文是本地工程门禁记录，不代表获准部署生产资产或接收用户 AUM。

## 已验证的本地门禁

以下命令均在仓库根目录按顺序执行并返回零状态码：

```text
bash script/v2/check-format.sh
git diff --check
forge test --summary
FOUNDRY_PROFILE=release forge test --match-path 'test/v2/invariants/**' --summary
FOUNDRY_PROFILE=release forge test --match-path 'test/v2/libraries/V2Math.t.sol' --summary
forge build --sizes
bash script/v2/check-contract-sizes.sh
bash script/v2/check-slither.sh
README 与 docs 的 canonical Markdown 链接检查
```

release invariant 使用每个 invariant harness 2,000 轮、每轮 200,000 次调用；release
数学测试中四个算术 fuzz 属性各执行 10,000 次。完整行为测试同时包含 legacy 回归和
V2 测试，均报告零失败。

V2 runtime size 门禁结果：

| 合约 | Runtime 字节 | 上限 |
| --- | ---: | ---: |
| AssetRegistry | 5,549 | 6,000 |
| DemeterManager | 21,706 | 22,000 |
| IndexPolicy | 13,520 | 14,000 |
| AuctionRebalance | 23,481 | 23,500 |
| DemeterBasketRouter | 5,341 | 6,000 |

Slither 0.11.3 使用 `--fail-high` 完成。92 条结果已写入静态分析分类文档；门禁未报告
未解决的 V2 Critical/High 问题，但这不能替代独立安全审计。

补充单位、舍入方向、授权和生命周期语义后的 V2 接口 NatSpec 编译 fixture 也已通过。

## 交付阻塞项

- 当前环境的 `.git` 目录只读。`git commit` 无法创建 `.git/index.lock`，因此实施计划
  要求的逐切片提交尚不存在。
- 尚未提供生产链、首批批准资产、真实 RPC、已部署 Timelock 角色、生产 fork fixture、
  经济仿真报告或独立审计，因此发布清单仍不能签字。
- 首池 AUM 上限已明确为运营软上限，不是比例 issue 路径中的链上硬上限。

Git 和生产配置可用后，应重新执行本证据集，补充生产 fork 与仿真产物、取得独立审计，
并按实施计划创建准确的逐切片提交。
