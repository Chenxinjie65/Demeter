# Demeter V2 路线图

[English](../ROADMAP_V2.md)

> 状态：基于拍卖的链上指数基金实施顺序。
>
> 修订日期：2026-09-05
>
> 每个合约、测试和 git 提交的详细执行要求见
> [V2 实施计划](IMPLEMENTATION_PLAN_V2_ZH.md)。

## 1. 交付原则

V2 是受控重写。现有 Factory、BeaconProxy 和旧 vault 代码仅作为测试、部署
和历史问题参考，不作为新协议基础。

交付顺序优先保证基金安全，而不是优先扩展功能：

```text
按比例索取权 -> 储备会计 -> 政策边界 -> 拍卖结算
-> 可选用户体验 -> 可选 solver 集成
```

在基金通过按储备比例赎回和有界拍卖的 fuzz/invariant 测试前，不得加入主动
DEX 交易、收益策略、通用回调、通用 hooks 或任意外部调用。

## 2. 保留、重写与延后

### 2.1 作为参考保留

- `src/modules/oracle/ChainlinkOracle.sol`
- `src/modules/governance/AssetWhitelist.sol`
- `src/libraries/Errors.sol`
- `src/libraries/FlashAccounting.sol`
- `src/libraries/TransientLock.sol`
- `test/mocks/*`
- `research/rebalancing_study/*`

这些文件只能提取模式，不能未经审查直接作为 V2 依赖。尤其是 flash accounting
和 transient lock 延后到未来经过审计的 solver adapter。

### 2.2 V2 不继续扩展的 legacy 路径

- `src/core/DemeterVault.sol`
- `src/core/DemeterFactory.sol`
- `src/core/DemeterRouter.sol`（V2 使用 `DemeterBasketRouter.sol`）
- `src/libraries/VaultStorage.sol`
- `src/libraries/VaultMath.sol`
- `src/modules/adapters/AaveV3Adapter.sol`
- `src/modules/circuit-breaker/CircuitBreaker.sol`
- `script/CreateFund.s.sol`

### 2.3 不属于当前核心

- 加权 AMM 定价和公共池 swap；
- Manager 主动 DEX 交易和任意 calldata；
- passive trajectory、动态费率和任意 hooks；
- Aave 或其他外部收益策略；
- 通用 flash callback、solver callback；
- 跨链池和 Manager 升级代理。

## 3. 实施阶段

### Phase 0：冻结基金与拍卖规范

交付架构、白皮书、本实施计划、状态结构、单位/舍入约定、支持资产政策及
安全不变量。完成标准是：所有 share 都明确为按比例索取权；没有文档将 AMM
swap 当作基金调仓路径；预言机和拍卖边界无歧义；任何角色都不能自由移动储备。

### Phase 1：类型、Registry、单例托管与按比例索取权

先实现 `PoolId`、types、`AssetRegistry` 与共同报价预言机配置，再实现
`DemeterManager`、`DemeterShare`、`ProportionalMath` 和核心接口。
支持无需许可建池（仅限已启用资产和全局安全边界）、固定资产顺序、一次性种子初始化、按比例 issue/redeem、ERC-20
转账/授权和聚合储备覆盖检查。

不加入调仓、DEX、费用或正式暂停系统。必须通过按比例申赎 fuzz，
证明捐赠 token 不改变记录储备，且 Manager 实际余额始终覆盖聚合储备。

### Phase 2：资产 Registry 与预言机保护

实现 Chainlink 校验、外部 Uniswap V3 common-quote TWAP adapter、`OracleGuard`
和版本化 creator policy。测试覆盖 round、新鲜度、sequencer、两个共同报价观察的
方向/decimals、双源偏差，以及 Managed/Immutable；issue/redeem 不依赖价格源。

### Phase 3：指数政策与调仓计划

实现 `IndexPolicy` 和调仓计划。池 creator 可在全局边界内发布政策，包含 epoch、目标
权重、漂移触发/目标区间、计划频率、单资产及总换手上限、拍卖价格边界和预言机
边界。计划存 target raw amounts + snapshot supply，并统一缩放全部差额。政策不能
覆盖活跃计划，也不能修改储备或份额供应。

### Phase 4：有界荷兰拍卖

实现 `AuctionRebalance`、`AuctionMath` 和直接 ERC-20 出价。每池同一时间只能有
一场资产对拍卖；拍卖具有固定起始溢价、最大折价、期限、lot 和总换手预算；
允许连续部分成交和到期；配置变化可公开使计划失效，瞬时价格异常时仅 Guardian
可取消 Planned 或 AuctionActive 计划。

必须证明成交不超过当前 surplus/deficit、计划换手和 Manager 余额；成交价不差于
冻结的结束价；预言机失效会阻止出价；拍卖失败不会影响赎回。

### Phase 5：Basket Router 与用户流程

实现直接 in-kind `DemeterBasketRouter`，只用 caller 资产和精确临时 Manager
allowance；结束为零余额/零 allowance，不含 DEX。单币 adapter 另行审查。

### Phase 6：运行控制与可选 solver

加入 guardian 对申购、计划、开拍和出价的暂停，不能暂停赎回；加入监控事件、
部署脚本和事故手册。solver 只能作为经过治理白名单和审计的受限 fill adapter，
不得给 Manager 增加任意外部调用能力。

## 4. 测试要求

必须包含：

1. 每个 issue、redeem、政策和拍卖原语的单元测试；
2. 储备比例、舍入、聚合覆盖的 fuzz/invariant 测试；
3. 拍卖价格、lot、部分成交、到期和取消测试；
4. issue、redeem、bid、cancel、pause 随机序列不变量测试；
5. 预言机过期、分歧、revert、sequencer down 测试；
6. false-return、异常 decimals、fee-on-transfer、rebasing、callback token 测试；
7. 生产资产对应 Chainlink feed 与 TWAP 池的 fork 测试。

## 5. 研究与上线要求

现有模拟器只是历史比较工具，不是执行证明。上线前必须加入日内价格、拍卖
延迟、部分/零成交、价格带失效、gas、对冲成本、竞拍者竞争和 AUM 缩放 lot
压力测试。

首个生产池只使用少量高流动性资产，并由运营执行保守 AUM 软上限。提高该软上限必须有真实
成交质量、价格冲击和预言机稳定性证据，不能只依赖有利回测。

## 6. 当前执行来源

逐切片完成标准、测试命令与 commit 边界只以 `IMPLEMENTATION_PLAN_V2_ZH.md` 为准；
发布状态和外部阻塞项见 `RELEASE_CHECKLIST_V2_ZH.md`，路线图不维护动态“下一任务”。
