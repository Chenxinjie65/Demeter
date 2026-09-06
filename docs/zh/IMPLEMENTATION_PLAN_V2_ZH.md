# Demeter V2 实施计划

[English](../IMPLEMENTATION_PLAN_V2.md)

> 状态：基于拍卖的 V2 指数基金绑定实施计划。
>
> 修订日期：2026-09-05
>
> 读者：AI 编程代理和代码审查者。每个切片都必须独立实现、测试、提交，
> 通过后才能开始下一个切片。

## 1. 每个切片的共同规则

1. 修改 V2 代码前阅读英文 `ARCHITECTURE_V2.md`、`REBALANCING_WHITEPAPER.md`
   和本计划；中文版本用于理解，英文版本是实现权威来源。
2. V2 功能切片不得顺手重写或删除 legacy 合约；新代码放在 V2 路径中。
3. 使用 Solidity `^0.8.24`、Foundry、自定义 error 和完整英文 NatSpec；正式规范
   使用英文，并在 `docs/zh/` 维护同步中文镜像。
4. 每个切片必须包含实现、聚焦单测、与风险相称的 fuzz/invariant 测试、
   `forge fmt`，以及该切片规定的命令。
5. 不得用 `vm.assume` 掩盖正确性问题；应限制输入或证明前置条件。
6. 第一阶段禁止通用 `call`/`delegatecall`、Router 授权、外部收益策略、
   callback 和公共 AMM swap。
7. 只有测试通过后才能提交。一个 commit 只包含一个行为完整的切片。

普通切片的验收命令：

```bash
bash script/v2/check-format.sh && forge test --match-path '<focused-test-path>' -vvv
```

每个里程碑和合并前运行：

```bash
bash script/v2/check-format.sh && forge test -vvv
```

全部 V2 格式路径以 `script/v2/check-format.sh` 为准。Legacy 原型不纳入格式门禁，
但仍纳入全仓行为测试。

## 2. 源码目录

```text
src/
  core/
    AssetRegistry.sol             # 资产准入、风险配置、guardian
    DemeterManager.sol            # 唯一托管和储备账本
    DemeterShare.sol              # 每池 ERC-20，只有 Manager 可铸销
    IndexPolicy.sol               # timelock 政策版本
    AuctionRebalance.sol          # 计划与拍卖状态，不托管资产
    DemeterBasketRouter.sol       # 用户自有 in-kind 路由
  oracle/
    UniswapV3TwapOracle.sol       # 无状态、批准池的 TWAP adapter
  interfaces/
    IAssetRegistry.sol
    IDemeterManager.sol
    IDemeterShare.sol
    IIndexPolicy.sol
    IAuctionRebalance.sol
    IDemeterBasketRouter.sol
    ITwapOracle.sol
    external/IChainlinkAggregator.sol
    external/IUniswapV3Pool.sol
  libraries/
    PoolId.sol
    ProportionalMath.sol
    AuctionMath.sol
    OracleGuard.sol
    V2Validation.sol
    V2Errors.sol
  types/
    PoolTypes.sol
    RebalanceTypes.sol
test/v2/
  core/ oracle/ libraries/ invariants/ integration/
test/v2/mocks/
```

## 3. 合约职责

### `AssetRegistry`

拥有支持资产、已验证 decimals、Chainlink feed、最大过期时间、每项非共同报价资产对
全局共同报价资产的 Uniswap V3 TWAP 池、窗口、偏差限制、timelock 和 guardian。共同
报价资产不配置 quote/quote 池，以 Chainlink USD 值作为 numeraire。只有治理 timelock
可写入；不托管资产，不计算份额，不创建计划，不批准 token。

Registry 构造器拒绝 EOA timelock。硬时间边界为：TWAP 5 分钟至 7 天，Chainlink stale
最多 7 天；配置 L2 sequencer 时，grace period 为 1 分钟至 1 天。

准入时读取并固定 `decimals()`。资产必须是标准 ERC-20；fee-on-transfer、
rebasing、ERC-777/callback 等类别由治理准入和生产资产门禁排除。运行时精确余额差
检查拒绝 fee/balance-changing 行为，callback fixture 证明资产操作期间不能改写
Manager、Policy 或 Auction 状态。Registry 不能在链上证明历史流动性，资产流动性
审查必须是治理流程的一部分。

### `DemeterShare`

拥有单个 `poolId` 的 ERC-20 supply、余额和 allowance。持有人可转账/授权，只有
immutable Manager 能铸造和销毁。它不持有基础资产、不读取权重、不调用外部合约，
固定 18 decimals。

### `DemeterManager`

拥有所有池的记录储备、每资产聚合储备、池元数据、资产顺序、creator、bootstrap/closed
状态和 share 地址。任何地址都可在已启用资产和全局边界内调用 `createPool`；timelock
在首池前一次性设置 Policy 与 AuctionRebalance；只有记录的 bootstrapper 可触发一次
bootstrap（标准 ERC-20 allowance 不绑定 poolId，不能用普通 relayer 代办），资金只从
该账户拉取；用户可比例 issue/redeem；只有 AuctionRebalance 可调用
`settleAuctionBid`。

Manager 不调用 DEX、不保存目标权重、不用预言机计算份额、不接收任意 calldata。
每次流出前后都要证明：

```text
IERC20(asset).balanceOf(address(manager)) >= accountedReserve[asset]
```

非请求的 token 捐赠不是记录储备，不能立即改变任何 holder 的索取权。

### `IndexPolicy`

拥有每池 append-only 政策版本和当前版本，不托管资产。版本包括 epoch、目标权重、
`triggerBps`、`destinationBps`、最小计划间隔、计划期限、单资产/总换手限制、
拍卖曲线和预言机限制。池 creator 可在全局边界内发布；旧版本发布后不可改写，活跃版本在
新版本生效前继续有效。

协议硬边界要求 policy delay 与最小 plan interval 至少 5 分钟、plan duration 最多
30 天、auction duration 至少 5 分钟；部署治理只能设置更严格值。

### `AuctionRebalance`

拥有计划、参考快照、target raw amounts、snapshot supply、已用换手、nonce 和每池
一场活跃拍卖。公开调用可启动计划、开拍、出价、到期拍卖和使旧配置计划失效；
guardian 可取消 Planned 或 AuctionActive 计划并暂停计划/拍卖。它不托管资产、不批准 DEX、不调用 bidder callback、
不改变政策边界。

每笔 bid 先计算成交，再调用 Manager 一次。Manager 在同一事务中从竞拍者收到
`buyAsset`，向竞拍者发送 `sellAsset`，最后更新两个储备。

### 预言机组件与 Router

`UniswapV3TwapOracle` 只读取 Registry 批准的池和窗口，必须使用审计过的
Uniswap V3 observation/tick math。`OracleGuard` 组合 Chainlink 与 TWAP，并检查
新鲜度、sequencer、偏差及冻结参考价变动。

Router 只能处理用户或已完成赎回所得资产。未来 solver 必须是独立的、治理白名单
且经审计的受限 adapter；不能给 Manager 任意外部调用能力。

## 4. 类型、单位和部署

`PoolTypes.sol` 定义 `PoolKey`、`CreatePoolParams`、`PoolConfig`、`AssetConfig`；
`RebalanceTypes.sol` 定义 `PolicyParams`、`PolicyVersion`、`PriceSnapshot`、
`RebalancePlan`、`Auction`、`BidParams`。

`poolId` 只由 `chainId`、Manager、creator、资产顺序、policy family 和 creator salt 派生；
不包含 mutable 权重、费用、预言机参数、政策版本或 share 地址。Manager 先计算
ID，再用 ID 作为 `CREATE2` salt 部署 share。

每个 BPS 使用 `uint16`，归一化价格使用 WAD `1e18`，token 数量使用原生单位。
所有转换使用注明舍入方向的 `mulDiv`。部署顺序：Timelock -> AssetRegistry ->
Manager -> IndexPolicy -> TWAP Oracle -> AuctionRebalance -> Timelock 同批一次性设置
policy 与 auction authority -> 启用资产；之后任何地址均可建池、发布有界政策；只有
记录的 bootstrapper 可执行 bootstrap。

仓库中的运维顺序为：`DeployV2Core.s.sol` 部署不可变核心；`WireV2Core.s.sol` 通过
Timelock 配置两个 Manager 链接；治理启用共同报价/其他资产和 policy family；
`CreateV2Pool.s.sol` 创建 creator-bound 池并发布 policy v1；延迟后由
`ActivateAndBootstrapV2Pool.s.sol` 激活 v1 并精确注入 committed basket。

## 5. AI 执行切片

### Slice 0：文档冻结

确认无需许可建池、creator-bound ID、ERC-20、无代理、共同报价 TWAP、closed、
disabled redemption 和 Managed/Immutable 在全部中英文文档一致。

测试：`git diff --check`，检查所有 Markdown 本地链接。

提交：`docs: add V2 implementation architecture and delivery plan`

### Slice 1：类型、Error 和接口

实现 V2 types、custom errors、接口骨架和单位 NatSpec，不实现核心合约。

测试：零地址、重复资产、数组长度、BPS 归一化、`destinationBps >= triggerBps`
等校验；`forge build` 通过；不得导入 legacy vault/adapter/router。

提交：`feat(types): define V2 pool policy and auction interfaces`

### Slice 2：ID 和算术库

实现 `PoolId`、`ProportionalMath`、非预言机的 `AuctionMath`，使用审计过的 mulDiv。

测试：同一不可变 key 的 ID 稳定；修改 chain/Manager/顺序/family/salt 会改变 ID；
权重变化和 share 地址不影响 ID；issue 向上舍入、redeem 向下舍入；无溢出/零除；
拍卖价格在起点为 `Pstart`、终点为 `Pend`、单调且不低于 `Pend`。算术 fuzz 至少
10,000 runs。

提交：`feat(math): add deterministic pool and proportional accounting math`

### Slice 3：AssetRegistry 和测试 Token

实现 Registry、接口、Chainlink/Uniswap 接口和标准/异常 token mocks。固定 decimals。

测试：只有 timelock 能写；零地址、无效 decimals、零 TWAP 窗口、无效 BPS、禁用报价
资产、自引用池均 revert；decimals 不可改变；guardian 只能治理轮换；不支持 token
被拒绝。

提交：`feat(registry): add V2 asset admission and risk configuration`

### Slice 4：Share、建池和 Bootstrap

实现 `DemeterShare`、最小 Manager、`createPool` 和一次性 `bootstrap`，Manager 使用
CREATE2 部署 share。

测试：任意地址可建有效池；重复 ID、禁用/重复/错误顺序资产和全局参数越界均正确处理；预测地址等于
部署地址；只有 Manager 铸销；只有指定 bootstrapper 可在期限内触发一次，资金仅从
该账户拉取并只向固定 recipient 铸造；并测试攻击者不能通过另一个 pool 消耗该
bootstrapper 对 Manager 的 allowance；错误数组、零种子、实际收到数量不等于请求
数量均 revert；bootstrap 前不能 issue/redeem。

提交：`feat(core): add V2 pool bootstrap and transferable shares`

### Slice 5：按比例 Issue/Redeem

实现 Manager `issue`、`redeem`、`maxAmountsIn`、`minAmountsOut`，使用 CEI、
OpenZeppelin `SafeERC20`、实际收到数量检查和重入保护。

测试：按 `ceil(reserve * shares / supply)` 收入，按 `floor(...)` 输出；零份额、余额
不足、数组错误、滑点边界均测试；捐赠不改变记录储备；转账失败回滚；任意两用户
随机 issue/transfer/approve/redeem 序列不能提取超过按比例索取权加有限 dust。

Invariant：聚合记录储备始终被 Manager 实际余额覆盖，share supply 等于 token supply。
至少运行 1,000 invariant runs。

提交：`feat(core): implement proportional issue and redemption`

### Slice 6：Chainlink 与 Uniswap V3 TWAP Guard

实现 `UniswapV3TwapOracle`、`ITwapOracle`、`OracleGuard`，仅引入必要的审计过数学
代码并保留许可证。

测试：Chainlink 非正、过期、不完整、revert、错误 decimals；sequencer down/宽限期；
每项非共同报价资产使用 asset/common-quote 池与窗口；共同报价资产以 Chainlink 作为
numeraire，`X/Y` 由两条共同报价观察之比推导，并
测试 token 顺序和 decimals；双源在偏差内通过、超出一个 BPS 失败；冻结参考带边界
包含端点、超出失败；issue/redeem 测试不依赖价格。

完成还需要每个生产 feed/TWAP 对的 fork 测试。

提交：`feat(oracle): add dual-source auction price guard`

### Slice 7：版本化 IndexPolicy

实现 creator 在治理全局边界内发布、公开激活和只读查询。政策必须匹配 Manager
资产数量与顺序；Immutable 只接受首版，Managed 才可追加版本。

测试：池 creator 只能为自己的池发布；生效时间必须在未来；只能一个 pending；权重和为 BPS、
非零、顺序正确；触发/目标、费用/期限/换手边界错误均 revert；生效前旧政策继续
有效；政策激活不改变储备和 share supply。

提交：`feat(policy): add permissionless bounded index policy versions`

### Slice 8：调仓计划生命周期

实现 `startPlan`、快照、漂移、target raw amounts + snapshot supply、统一缩放、频率、
单资产/总换手、到期和 guardian 取消；fixture 中一次性配置 Manager authorities。

测试：必须有 bootstrap、active policy、无活跃计划、双源有效和日历/漂移触发；独立
计算核对 actual weights、scaled targets、surplus/deficit、turnover；滞回、最小间隔、
到期、每计划上限与推导最大换手速率、不可覆盖/放宽；创建计划不移动资产。拍卖结束后
必须显式调用 `expireAuction`；过期计划必须显式调用 `invalidatePlan` 后才能创建新计划
或全额赎回。

提交：`feat(rebalance): add bounded policy plan lifecycle`

### Slice 9：开拍与报价

实现 surplus/deficit lot、线性价格曲线和 `openAuction`，每池只有一场 active auction。

测试：只有活跃未过期计划可开拍；`Pstart`/`Pend`/期限来自不可变计划；错误资产、无
surplus/deficit、零 lot、并发、过期均 revert；开拍后赎回只能改变后续 lot，不能改变
冻结曲线；到期不修改储备。Fuzz 证明价格单调、lot 不超储备/deficit/预算。

提交：`feat(auction): add bounded auction creation and quoting`

### Slice 10：直接 Bid 与原子结算

实现 `bid` 和 Manager `settleAuctionBid`，成交前计算实际支付，Manager 同事务收买入
资产、发卖出资产、更新储备。

Manager 的所有资产操作共用一个 transient reentrancy guard，并向固定的 Policy 与
Auction 模块只读暴露 guard 状态；token callback 不能在检查与结算之间激活政策、启动
计划、使有效计划失效或取消拍卖。

测试：完整/部分成交数量精确；低于当前价、超过 lot、`maxBuyAmount`、过期、预言机
不安全均 revert；仅 AuctionRebalance 可结算；任一转账失败回滚全部状态；重复 bid
不能超过边界；重入 token 不能进入 bid/issue/redeem/settlement。

随机 issue/redeem/plan/open/bid/cancel/expire invariant 至少 2,000 runs。此切片是
第一版功能完整的基金核心发布点。

提交：`feat(auction): settle direct bids against manager reserves`

### Slice 11：运行控制、事件和查询

实现 Guardian 暂停 issue、plan、open、bid（仅 Timelock 可解除）；必须的事件、储备/政策/计划/拍卖查询和
执行指标。赎回不可暂停。

测试：guardian 权限、暂停前置检查、任何暂停/拍卖状态均可 redeem；事件包含 pool ID、
版本/nonce、参考价、fill、换手和取消原因；`quoteBid` 与同区块执行 quote 一致，并在
暂停、过期、配置变化或预言机不安全时 fail closed。

提交：`feat(ops): add guardian controls and auction observability`

### Slice 12：Router

实现 `DemeterBasketRouter` in-kind wrapper；它只用 caller 资产，对 Manager 使用精确
临时 allowance，结束为零余额/零 allowance，且不含 DEX。单币 adapter 单独审查。

测试：与 Manager 直接调用会计等价；用户 min-in/min-out；失败回滚/退款；Router 零余额、
无 Manager allowance；不能调用 auction settlement 或改变拍卖。

提交：`feat(router): add user-owned basket routing`

### Slice 13：Fork、部署与发布门禁

实现每网络部署配置、bootstrap/政策发布脚本和生产资产 fork 测试。运行静态分析与
独立安全审查。

证据：每个 feed/TWAP 的真实读取、方向、decimals、窗口；本地完整创建/初始化/申赎/
计划/开拍/部分成交；部署断言两个一次性 authority、immutable 链接和角色；`forge test -vvv`、
`forge build --sizes`、静态分析无未解决高危；模拟包含部分/零成交、价格跳变、过期
feed 和 AUM 缩放 lot。

完成条件：发布清单签字、安全审计无 critical/high 未解决问题，运营侧执行书面保守的
首池 AUM 软上限并有监控。该上限不是申购路径的链上硬不变量；硬上限必须另行设计和测试。

提交：`chore(release): add V2 deployment and release-gate checks`

## 6. 里程碑门禁

| 里程碑 | 切片 | 合并门禁 |
| --- | --- | --- |
| M1：索取权安全 | 0-5 | 全部单测、fuzz、比例 invariant 通过 |
| M2：价格安全 | 6-8 | 预言机失败与不可变政策测试通过 |
| M3：拍卖安全 | 9-11 | 拍卖 invariant 通过，任意状态可赎回 |
| M4：用户与上线 | 12-13 | fork、部署、静态分析和审计通过 |

AI 遇到新资产类别、新预言机、多跳 TWAP、成分迁移、DEX adapter、solver callback、
费用或收益部署时，必须停止并请求新的架构决策，不能自行扩展边界。
