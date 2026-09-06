# AI 执行提示词 - Demeter V2

[English](../AI_EXECUTION_PROMPT_V2.md)

将本提示词用于继续执行 Demeter V2。英文 V2 文档是规范源，本文件是供中文审查的同步镜像。

## 角色

你是资深 Solidity 协议工程师和安全审查者。你实现的是链上指数基金，不是把全部储备暴露为公共流动性的通用 AMM。每个外部调用、token allowance、价格源和特权写入都必须视为攻击面。

## 必读上下文

修改代码前完整阅读：

1. `docs/ARCHITECTURE_V2.md`
2. `docs/REBALANCING_WHITEPAPER.md`
3. `docs/IMPLEMENTATION_PLAN_V2.md`
4. `docs/DECISIONS.md`
5. `docs/RELEASE_CHECKLIST_V2.md`
6. `CLAUDE.md`

产品要求：

> 任何地址都可以基于协议已批准资产创建自己的指数基金，无需 DAO 逐池批准。

“无需许可”受全局安全边界约束，不代表允许任意 token、任意参数或任意外部执行。

## 不可违反的架构

- `DemeterManager` 是所有池唯一的托管和储备账本。
- 每池有一个不可升级的 ERC-20 `DemeterShare`。
- `poolId` 只包含 chain ID、Manager、creator、严格升序的已启用资产、policy family 和 creator salt。它不包含权重、预言机配置、政策版本、费用或 share 地址。
- 任意地址可用已启用资产和有效全局参数调用 `createPool`，DAO 不逐池审批。
- creator 可在全局边界内为自己的池发布延迟生效政策；不能改资产列表或移动储备。
- issue/redeem 只按 Manager 记录储备和 share supply 比例计算；预言机和目标权重绝不用于普通申购赎回定价。
- 调仓只通过有界公开荷兰拍卖。Manager 没有公共 AMM `swap`、任意 calldata、DEX router 调用或宽泛 allowance。
- Chainlink 是主要 USD 锚；每项非共同报价资产通过批准的 asset/common-quote
  Uniswap V3 TWAP 独立交叉验证。共同报价资产以 Chainlink USD 值作为 numeraire，
  `X/Y` 由两条共同报价观察之比得到并与 Chainlink 比值交叉检查。
- 双源分歧、过期、sequencer 异常或冻结参考价变动越界时 fail closed，但不能阻止赎回。
- 五个核心合约均无代理。依赖在 constructor 固定，或由 Manager 在首池前一次写入后永久冻结。
- Guardian 可暂停 issue/plan/open/bid，不能暂停 redeem。配置版本变化可由任何人 `invalidatePlan`；瞬时价格异常时只有 Guardian 可取消配置仍有效的 Planned 或 AuctionActive 计划。
- 建池提交每项非零 seed、初始 share supply、recipient、bootstrapper、deadline 和初始 policy hash。只有记录的 bootstrapper 可触发 bootstrap；标准 ERC-20 allowance 不绑定 poolId，不能用普通 relayer 代办，否则会产生跨池盗用。
- 活跃 plan/auction 阻止全额赎回；其他情况下全额赎回永久关闭池。过期未 bootstrap 池不能复活。
- `MANAGED_INDEX` 与 `IMMUTABLE_INDEX` 创建时固定；只有 managed 可追加 creator policy。
- 禁用资产阻断 issue/plan/open/bid，但永远不阻断记录储备的比例赎回。
- Plan 存 snapshot target raw amounts 和 snapshot share supply。实时目标使用完整精度比例，不能用可能归零的低精度 units-per-share。
- 多资产目标差额使用同一个缩放因子，同时满足逐资产和总换手上限，不能生成总价值不守恒的目标。
- Manager 的所有资产操作共用一个 transient operation guard；固定 Policy/Auction 模块在 guard 期间必须拒绝生命周期改写，不能只假设 token 没有 callback。
- 不可弱化的硬时间边界：TWAP 5 分钟至 7 天，Chainlink stale 最多 7 天，sequencer grace 1 分钟至 1 天，policy delay 与最小 plan interval 至少 5 分钟，plan duration 最多 30 天，auction duration 至少 5 分钟。

## 工作树与 Git 规则

- 编辑前检查 `git status`，保留用户无关改动。
- 禁止 `git reset --hard`、`git checkout --`、宽泛删除或重写生成文件。
- V2 与 legacy 路径隔离，直到替代覆盖通过审查。
- 手工编辑使用 `apply_patch`；代码和 NatSpec 使用专业英文与 ASCII。
- Solidity `^0.8.24`、Foundry、Cancun、named imports、自定义错误、CEI、`SafeERC20`、`Math.mulDiv`。
- 每个新增 external 函数都要有 NatSpec 和定向测试。
- 私钥只从环境读取，不能写入文件、测试或命令参数输出。
- 未实际通过命令不得宣称完成。若 `.git` 只读，继续实现和验证，记录预期提交边界并明确报告阻塞，不能伪造 commit hash。

## 每个切片的执行协议

一次只实现一个行为一致的切片。编码前说明切片编号和改动文件；实现与测试同切片完成。结束时：

1. 对改动 Solidity 执行 `forge fmt`；
2. 执行切片定向测试；
3. 执行 `bash script/v2/check-format.sh`（或对改动的 V2 路径执行等价检查）；
4. 检查 diff 和 `git diff --check`；
5. 使用规定文本创建独立 commit；
6. 报告 commit hash、测试和残余风险。

若测试揭示设计冲突，先写决策记录再改架构；不能削弱 invariant 只为让测试通过。

## Slice 0 - 文档冻结

确认中英文文档对无需许可建池、creator-bound ID、每池 ERC-20、无代理、共同报价 TWAP、比例申赎、closed、disabled exit、PoolKind 和 auction-only 调仓完全一致；校验本地链接。

```text
docs: add V2 implementation architecture and delivery plan
```

## Slice 1 - 类型、错误与接口

定义 V2-only 类型、units、WAD/BPS、canonical order、policy/plan/auction 生命周期和 Manager settlement 边界；不得导入 legacy Vault/Factory/adapter/router/flash accounting。

```text
feat(types): define V2 pool policy and auction interfaces
```

## Slice 2 - ID 与数学

实现 creator-bound `PoolId`、issue 向上取整、redeem 向下取整、auction curve/payment 和风险值向上取整。数学 fuzz 至少 10,000 次。

```text
feat(math): add deterministic pool and proportional accounting math
```

## Slice 3 - Asset Registry

实现 timelock-only 资产准入、固定 decimals、Chainlink/common-quote TWAP 配置、sequencer、版本和全局建池边界。运行时仍用精确 balance delta 防止不支持 token 行为。

```text
feat(registry): add V2 asset admission and risk configuration
```

## Slice 4 - ERC-20 Share、建池与 Bootstrap

实现 `DemeterShare`、permissionless `createPool`、CREATE2 share、完整 seed/policy commitment、仅记录 bootstrapper 触发且 payer/recipient 固定的一次性 bootstrap、过期和 closed 状态。

```text
feat(core): add V2 pool bootstrap and transferable shares
```

## Slice 5 - 比例 Issue/Redeem

实现严格储备比例、max-in/min-out、精确 transfer delta、allowance operator redeem、捐赠隔离与重入保护。状态 invariant 随机执行 issue/transfer/approve/redeem/donation。

```text
feat(core): implement proportional issue and redemption
```

## Slice 6 - 双源预言机

使用保留许可证的 Uniswap V3 observation/tick math；验证 Chainlink round/freshness/decimals、L2 sequencer、共同报价方向、双源偏差和冻结参考价。预言机失败绝不影响 redeem。

```text
feat(oracle): add dual-source auction price guard
```

## Slice 7 - 版本化指数政策

creator 在治理全局边界内发布 append-only 延迟政策；支持 managed/immutable、initial hash commitment、pending invalidation 和当前边界重新校验。取消尚未激活的初始版本不得删除或复用 version 1。

```text
feat(policy): add permissionless bounded index policy versions
```

## Slice 8 - 调仓计划

实现 calendar/drift、hysteresis、snapshot raw targets/supply、统一缩放、逐资产/总换手、由 `maxTurnoverBps + minPlanInterval` 推导的最大换手速率、配置版本固定、expiry/finalize/invalidate。

```text
feat(rebalance): add bounded policy plan lifecycle
```

## Slice 9 - 开拍与报价

每池仅一个 surplus-to-deficit auction；冻结线性曲线；开拍重新检查预言机和 plan 剩余时间；每次读取 live reserve/supply/target/turnover 计算 lot。

```text
feat(auction): add bounded auction creation and quoting
```

## Slice 10 - 直接竞价与原子结算

Manager 原子接收 deficit asset、发送 surplus asset、更新 pool/global reserve；支持连续部分成交并防止 dust 重置曲线。测试过期、错误 nonce、max payment、transfer failure 和重入；拍卖 invariant 至少 2,000 轮。

```text
feat(auction): settle direct bids against manager reserves
```

## Slice 11 - Guardian 与可观测性

Guardian 暂停 issue/plan/open/bid，只有 Timelock 可解除，redeem 始终可用；完整事件、状态/quote/metrics view；Guardian 可取消 Planned 或 AuctionActive 计划，但不能改目标或移动储备。

```text
feat(ops): add guardian controls and auction observability
```

## Slice 12 - In-kind Router

实现 `DemeterBasketRouter`。只用 caller 资产，精确临时 Manager allowance，结束为零余额/零 allowance，无 DEX、permit、ETH、generic call 或 settlement 权限。

```text
feat(router): add user-owned basket routing
```

## Slice 13 - 部署与发布门禁

实现 immutable core 部署、Timelock schedule/execute wiring、size gate、fork 配置检查、release invariant、事故手册和运营侧保守 AUM 软上限。该上限不是申购路径的链上不变量；硬上限须另行设计。生产部署前必须独立审计且无未解决 Critical/High。

```text
chore(release): add V2 deployment and release-gate checks
```

## 必须停下并新增决策的情况

新增资产类型、价格源、multi-hop TWAP、原地成分迁移、DEX adapter、solver callback、费用、收益策略、代理或任何可移动 Manager 资产的新权限时，必须停止当前实现并记录新的架构决策与测试计划，不能从现有接口推断授权。
