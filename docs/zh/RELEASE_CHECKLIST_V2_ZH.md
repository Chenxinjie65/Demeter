# Demeter V2 发布检查清单

[English](../RELEASE_CHECKLIST_V2.md)

> 状态：强制发布门禁。本地测试通过不等于获准部署或接收 AUM。
>
> 修订日期：2026-09-05

## 1. 代码与规范

- [ ] 中英文 V2 文档对无需许可建池、比例份额、共同报价预言机、政策、拍卖和退出语义描述一致。
- [ ] V2 接口不导入旧 Vault、Beacon、AddressProvider、Aave adapter、通用 Router、callback 或 flash accounting。
- [ ] 每个外部写函数都有 NatSpec、自定义错误、定向测试和唯一状态所有者。
- [ ] 独立安全审计不存在未解决的 Critical/High 问题。

## 2. 确定性本地门禁

在仓库根目录执行：

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

必须满足：

- [ ] 所有命令返回 0；
- [ ] 比例索取权至少运行 1,000 轮 invariant；
- [ ] 拍卖生命周期至少运行 2,000 轮 invariant；
- [ ] 算术 fuzz 在 `FOUNDRY_PROFILE=release` 下至少运行 10,000 次；
- [ ] `AuctionRebalance` runtime bytecode 不超过 23,500 bytes；
- [ ] `DemeterManager` runtime bytecode 不超过 22,000 bytes，`AuctionRebalance`
  不超过 23,500 bytes；
- [ ] 任何核心合约接近 EIP-170 上限时均经过明确审查；
- [ ] 已审查的编译参数使用 via-IR 与 `optimizer_runs = 80`；生产环境修改该参数
  前必须重新执行 size 和 gas 审查；
- [ ] 静态分析结果已分类，且没有未解决 Critical/High。

固定测试依赖产生的 warning 必须单独记录，不能混同为项目自身 warning。
Legacy 原型有意不纳入 V2 格式门禁；不得只为适配当前 formatter 制造全仓格式 diff，
但全仓行为测试仍必须执行。

## 3. 治理与部署

- [ ] `V2_TIMELOCK` 是已部署的 `TimelockController`，不是 EOA。
- [ ] proposer、executor、canceller、admin 角色符合批准的多签/治理方案，部署 key 不保留意外权限。
- [ ] `DeployV2Core.s.sol` 的输出可由已审查源码与编译参数复现。
- [ ] 首池创建前，通过同一个 Timelock batch 调用 `setIndexPolicy` 与 `setAuctionRebalance`。
- [ ] `CreateV2Pool.s.sol` 推导预期 creator-bound ID，并发布 commitment 一致的 policy v1。
- [ ] `ActivateAndBootstrapV2Pool.s.sol` 仅在 `effectiveAt` 后运行，使用记录的 bootstrapper，
  并验证精确储备和初始 supply。
- [ ] 链上验证 Manager 一次性链接、Registry 角色、Auction immutable 和 Router 的 Manager 地址。
- [ ] 源码验证完成，部署 bytecode 与本地产物一致。
- [ ] Guardian 运维密钥和事故沟通路径经过演练。

## 4. 生产资产门禁

目标链和首批资产未选定前，本节不能签署：

- [ ] 每个资产均为标准、非 rebasing、非 fee-on-transfer、无 callback 的 ERC-20；
- [ ] 已审查 token decimals、Chainlink 方向/decimals/heartbeat 与 feed min/max 行为；
- [ ] 每个非共同报价资产都有经批准且流动性充足的 Uniswap V3 共同报价池；
- [ ] fork 测试覆盖 token 顺序、TWAP 方向/窗口/观察容量、decimals 归一化和双源偏差；
- [ ] L2 验证正确的 sequencer uptime feed 与 grace period；
- [ ] 模拟禁用每项资产：issue/plan/open/bid 停止，已记录储备仍可赎回。

## 5. 经济与运维门禁

- [ ] 模拟 partial fill、zero fill、stale feed、双源分歧、sequencer 中断、参考价跳变、拍卖到期和配置失效；
- [ ] 三资产以上场景证明统一目标缩放，并在逐资产上限下保持买卖名义价值平衡；
- [ ] 拍卖规模按真实外部流动性和 bidder 对冲成本测试，而非只看历史收盘价；
- [ ] 首池的 `maxTurnoverBps` 与 `minPlanInterval` 推导出的最大换手速率可接受；
- [ ] 首池设置保守 AUM 上限，并有提高上限的书面规则；
- [ ] 监控储备覆盖、预言机分歧、计划年龄、未成交名义量、实际折价和 Guardian 操作；
- [ ] 事故演练确认 issue/auction 暂停、Guardian 取消、旧计划公开失效以及赎回不中断。

## 6. 当前外部阻塞项

仓库尚未确定生产链、首批批准资产、已部署 Timelock、RPC endpoint 或完成独立审计。因此 fork、治理角色、审计和首笔 AUM 门禁保持未勾选，不能由 mock 测试通过推断完成。
