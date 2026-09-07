# Demeter V2 架构

[English](../ARCHITECTURE_V2.md)

> 状态：V2 `main` 分支的正式架构。
> 范围：Demeter 是链上指数基金，不是把全部金库储备提供为公开 swap
> 流动性的 AMM。

## 1. 产品定义

Demeter 将公开、规则化的指数封装为可转让 ERC-20 基金份额。每份份额都是
链上 ERC-20 资产篮子的按比例索取权。协议仅承担三项职责：

1. 托管并可验证地记录篮子储备；
2. 不依赖预言机定价稀释地申购和赎回按比例基金份额；
3. 使用有界、竞争性的拍卖，周期性地将篮子推向已发布指数。

任何人都可以从 `AssetRegistry` 已启用的资产集合创建自己的指数基金，无需 DAO
逐池批准。无需许可不等于任意 token 或任意参数：每个池必须满足协议全局安全边界。

基金不承诺 alpha；它承诺对既定方法论提供透明敞口，并披露跟踪误差和执行
成本。

## 2. 关键设计选择

### 2.1 单例托管，每池独立 ERC-20 份额

`DemeterManager` 是唯一的、不可升级的托管和会计合约。它持有所有池的基础
资产，并按 `poolId` 记录储备。每个池有一个不可升级的 `DemeterShare` ERC-20
合约；份额合约不托管资产，且只能由 Manager 铸造或销毁。

这把小型共享托管面与用户可见、可转让的凭证分开。每池一份份额合约不是每池
一座 vault 或 proxy。

### 2.2 申购与赎回始终按实际储备比例

已初始化池的储备为 `R[i]`、份额供应为 `S` 时：

```text
requiredIn[i] = ceil(R[i] * sharesOut / S)
amountOut[i]  = floor(R[i] * sharesIn  / S)
```

目标权重绝不决定普通用户实际交付或收到的资产。这无需预言机即可保护现有
持有人的索取权。建池提交每项非零 seed、初始份额供应、recipient、bootstrapper、
deadline 与初始 policy hash。只有记录的 bootstrapper 可调用 bootstrap；标准 ERC-20
allowance 不绑定 poolId，放开 relayer 会产生跨池盗用风险。Manager 从该 bootstrapper
精确拉取，且仅向记录的 recipient 铸造份额。

活跃计划或拍卖会暂停申购。赎回始终可用并按当前实际储备和供应比例执行。全额
赎回在活跃计划中被拒绝；其他情况下会转出最终储备并将池永久标记为 `closed`，
从而避免零供应活跃池。

### 2.3 使用拍卖调仓，而不是公共池 swap

正式执行路径是有界荷兰拍卖。竞拍者向 Manager 转入缺少的资产，并以当前拍卖
价格换取超配资产；Manager 原子更新储备。竞拍者可在任意 DEX 或 solver 中
取得、对冲或净额结算这笔交易，但基金没有通用 `swap` 入口，也不会给任意 DEX
router 授权。

拍卖使最大让价明确可见。未成交或部分成交只会保留跟踪误差，绝不会自行扩大
价格边界或强制低价交易。

### 2.4 双源预言机，失败即停止

每个非共同报价资产都必须具备经过正值、完整 round、新鲜度和 L2 sequencer 校验的
Chainlink USD feed，以及针对全局共同报价资产的已批准 DEX TWAP。共同报价资产本身
以经过校验的 Chainlink USD 值作为计价基准，不需要 quote/quote TWAP 池。因此每个
auction pair 仍有两条独立价格：Chainlink 比值，以及两条共同报价 TWAP 观察的比值
（共同报价腿直接使用 Chainlink 值）。

Chainlink 是主价值锚，DEX TWAP 独立交叉验证交易对价格。仅当两个来源都新鲜、
且偏差不超过池配置的上限时，才能创建新拍卖。每次出价还会检查当前双源报价仍
落在拍卖冻结参考价的变动带内。任一违例会让拍卖取消或不可成交，直到重新取得
参考快照。

预言机只定义保护边界，绝不用于普通申购或赎回定价。

### 2.5 核心合约不可升级

`DemeterManager`、`DemeterShare`、`AuctionRebalance`、`IndexPolicy` 和
`AssetRegistry` 均不使用代理。部署后托管与索取权边界不可变。缺陷通过暂停受影响
的非赎回路径、部署新版本并执行治理迁移处理，而不是替换实现合约。

关键依赖由构造函数固定；Manager 的 policy/auction 地址在首池前各写一次后永久
冻结。资产和预言机风险配置只能由 governance timelock 通过明确版本修改。

### 2.6 AssetRegistry 不是万能 AddressProvider

V2 不使用可以在运行时替换任意执行模块的通用地址表。`AssetRegistry` 仅负责资产
准入、decimals、Chainlink feed、外部 TWAP 源、风险参数以及 guardian/timelock 角色。
它不能把 Manager 托管或拍卖执行重定向到任意替代合约。

每次资产配置更新都递增版本。调仓计划记录所使用的配置版本；版本变化会使计划和
活跃拍卖失效，必须重新验证并取得价格快照。

## 3. 第一阶段非目标

第一阶段明确不包括：

- 加权不变量池 swap 和渐变 AMM 权重；
- Manager 主动 DEX 交易或任意 calldata 执行；
- 任意 hooks 或任意调仓模块；
- 外部借贷、质押或收益部署；
- 原生 ETH 托管、fee-on-transfer、rebasing、ERC-777 及其他带回调或余额变化
  特性的资产；
- Manager 升级和跨链支持。

建池在全局资产与参数安全政策内无需许可。所有成分必须已由 `AssetRegistry` 启用，
且每个池都要满足相同的资产数量、权重、换手、拍卖和预言机上限。

通用结算 `lock` 入口、回调和 EIP-1153 delta accounting 是后续执行工具，不属于
第一阶段基金会计路径；这不排除第 4.3 节的标准 transient reentrancy 互斥锁。未来
solver adapter 仅可在严格审计的接口后使用更广泛机制，且不得改变基金的申购、赎回
或拍卖不变量。

## 4. 正式合约形态

```text
Governance Timelock
        |
        +--> AssetRegistry --------> Chainlink feeds / DEX TWAP sources
        |
        +--> IndexPolicy ----------> published weights and rebalance bounds
        |
        +--> DemeterManager <------> DemeterShare(poolId)
                 |  ^
                 |  | proportional issue / redeem
                 v  |
          AuctionRebalance
                 ^
                 |
      bidders, market makers, and solver adapters
                 |
        external DEXs and liquidity venues
```

### 4.1 AssetRegistry

Registry 负责资产准入和预言机配置。它为每个资产存储不可变 decimals、Chainlink
feed、DEX TWAP oracle、TWAP 窗口和风险限制。资产准入由治理控制，并验证资产符合
协议支持的标准 ERC-20 政策。

Registry 记录 timelock 与 guardian。风险团队可在链下准备提案，但所有 Registry
写入都由 timelock 执行；没有独立的链上 risk-admin 写权限。
Timelock 必须是已部署合约。协议硬边界要求 TWAP 窗口为 5 分钟至 7 天，Chainlink
stale 上限为 7 天；配置 L2 sequencer 时，grace period 为 1 分钟至 1 天。生产参数仍
必须按具体 feed heartbeat、目标链和流动性进一步收紧。

### 4.2 状态所有权

每个可变事实只能有一个所有者；其他合约可以读取，但不得保留第二份权威副本。

| 状态 | 所有者 | 写入者 | 原因 |
| --- | --- | --- | --- |
| 资产准入、decimals、feeds、TWAP 配置、guardian | `AssetRegistry` | Governance timelock | 将全局风险配置与托管分离 |
| 池 key、资产顺序、creator、bootstrapper、储备、聚合储备、share token、closed | `DemeterManager` | 任何满足 Registry 限制的创建者；Manager 记录结果 | 托管账本是索取权唯一来源 |
| 政策版本与当前政策参数 | `IndexPolicy` | 池 creator 在全局边界内发布；治理只设全局边界 | 方法论无需许可且受约束 |
| 调仓计划、活跃拍卖、已用换手、计划/拍卖 nonce | `AuctionRebalance` | 受政策和预言机约束的公开调用 | 将执行状态置于托管账本外 |
| ERC-20 供应、余额、授权 | `DemeterShare` | Manager 铸销；持有人转账/授权 | 提供标准可转让凭证 |

`AuctionRebalance` 只能请求 `DemeterManager` 结算一笔已验证出价。Manager 从竞拍者
拉取买入资产、更新储备，并在同一交易中发送卖出资产。`AuctionRebalance` 不得托管
资产，`DemeterManager` 不得接收任意外部调用数据。

### 4.3 DemeterManager

Manager 是以下状态的唯一来源：不可变池配置和资产顺序、
`reserve[poolId][asset]` 与聚合记录储备、每池 `DemeterShare`、closed 状态、按比例
申购/赎回和原子拍卖结算。计划与拍卖状态只属于 `AuctionRebalance`。

Manager 不调用 DEX router、不批准任意 spender、不报价加权不变量，也不允许池间
直接净额结算。实际 ERC-20 余额不作为储备预言机：非请求转账只是超额余额，不能
改变任何池的索取权。

对每种资产，Manager 实际余额必须覆盖所有池的记录储备总和。第一阶段没有协议费
储备或其他出金会计类别。每条移动 token 的路径都检查这个全局不变量。

Manager 的全部资产操作共用一个 transient reentrancy guard。guard 生效期间，
`isPoolActive` 有意返回 false，`isOperationActive` 返回 true；固定的 Policy 与 Auction
模块据此拒绝 token callback 中的政策激活或生命周期改写。交易执行结束后，池的正常
活跃状态不变。

### 4.4 DemeterShare

`DemeterShare` 是最小 ERC-20 索取权 token，提供普通的转账和授权。只有 Manager
能铸造或销毁。第一版即支持可转让份额，不对用户暴露仅 Manager 内部使用的收据
格式。

### 4.5 IndexPolicy

`IndexPolicy` 保存版本化方法论状态，不托管资产。一个政策版本包含：不可变资产
范围、归一化目标权重、生效 epoch 和 creator commitment policy hash、日历频率、
漂移触发与目标区间、最大换手和单资产最大调整、拍卖期限、起始溢价、最大折价及
预言机边界。

池 creator 发布初始政策；若池类型允许，也可发布后续版本，但必须在协议全局边界
内。政策发布无需逐池治理批准，但必须记录 policy hash、具有 `effectiveAt` 延迟且
append-only。取消尚未激活的初始版本不会删除或复用 version 1；该池保持不可 bootstrap
状态，直到过期。`IMMUTABLE_INDEX` 只接受初始政策；`MANAGED_INDEX` 才允许 creator 追加
版本。治理只设置全局边界或禁用 policy family，不批准单个池。guardian 可冻结
新申购和调仓，但不能写入权重或激活替代政策。

政策时间也有不可弱化的协议硬边界：policy delay 与最小 plan interval 均至少 5 分钟，
plan duration 最多 30 天，auction duration 至少 5 分钟；治理只能设置更严格值。

### 4.6 AuctionRebalance

`AuctionRebalance` 是 Manager 授权的执行模块，不是独立托管人。每池同一时间只运行
一场有界拍卖。第一版仅支持直接 ERC-20 出价：

1. 竞拍者向 Manager 提供 `buyToken`；
2. Manager 向竞拍者发送 `sellToken`；
3. 原子更新储备及剩余 surplus/deficit。

第一阶段没有竞拍者回调。未来 solver fill 仅可作为独立审计的 adapter 加入，且必须
证明至少满足直接出价同等的 `minBuy` 和储备限制。

### 4.7 预言机组件

`OracleGuard` 是 `AuctionRebalance` 使用的无状态 library。它从 `AssetRegistry` 读取
不可变 decimals 元数据和预言机配置。`UniswapV3TwapOracle` 是无状态 adapter，使用
`observe()` 从批准的 Uniswap V3 池获得报价；它不能托管资产、接受任意池或写配置。
Registry 提供允许的池、报价资产和 TWAP 窗口。

首版为每项资产保存一个 asset/common-quote TWAP 池；`X/Y` 由两条共同报价观察之比
得到。任意 direct `X/Y` 映射、多跳 TWAP、备用源和非 Uniswap adapter 延后实现。

### 4.8 DemeterBasketRouter

`DemeterBasketRouter` 只包装 in-kind issue/redeem：调用开始时把 Router 中的意外
余额退回当前 caller，再拉取精确篮子，仅为 Manager 设置精确临时 allowance 并清零。
这样第三方捐赠不能永久阻断无状态 Router。redeem 由 Manager 直接发送至用户 receiver。
第一阶段没有单币 DEX 路由，新增 venue adapter 需要独立审查。

## 5. 池身份与状态

`poolId` 即使指数发布新权重也保持稳定，仅由不可变数据派生：

```text
poolId = keccak256(
    chainId,
    address(manager),
    creator,
    orderedAssets,
    policyFamilyId,
    creatorSalt
)
```

creator 绑定池所有权，防止公开 mempool calldata 被复制后抢占。目标权重、费率、
预言机参数、当前政策版本和 share 地址均被排除。Manager 先派生 `poolId`，再用该 ID
作为 `CREATE2` salt 部署 share。第一阶段资产不可变；成分变更迁移至新池，任何地址
仍可按全局边界创建该新池，无需逐池治理批准。

Manager 每池存储资产顺序与储备、share token、bootstrap commitment/expiry 和 closed
状态；政策和拍卖生命周期只从各自所有者合约读取，不复制权威状态。

## 6. 调仓模型

### 6.1 两类事件

协议区分：

1. **结构性指数更新。** 池 creator 在预定 epoch 发布新政策版本；版本要经过
   `effectiveAt` 延迟并满足全局政策边界，治理不逐池批准。
2. **漂移控制。** 政策不变，但实际价值权重超出配置区间；计划可以减少漂移，但不
   必须消除全部漂移。

对价格向量 `p`，实际权重为：

```text
a[i] = reserve[i] * p[i] / sum(reserve[j] * p[j])
drift = 1/2 * sum(abs(a[i] - targetWeight[i]))
```

仅当 `drift >= triggerBps` 且所有频率与换手限制满足时，才启动漂移计划。执行达到
严格位于触发区间内的 `destinationBps` 时停止；这个滞回带可避免重复小额交易。
第一阶段不保存独立 rolling-window 累加器；`maxTurnoverBps` 与 `minPlanInterval` 共同
给出确定的最大换手速率，治理必须配套设置。

### 6.2 创建计划

政策可用后，任何人均可在预言机数据新鲜时调用 `startPlan`。`AuctionRebalance` 会：

1. 验证所有资产的两个价格源；
2. 用当前参考总价值和政策权重计算 target raw amounts；
3. 对全部差额使用一个统一缩放因子，同时满足单资产与聚合换手上限；
4. 记录 nonce、target raw amounts、snapshot share supply、参考价格、配置版本和到期时间。

计划并不承诺达到精确目标。活跃计划不可被新计划覆盖。到期后，任何人必须先调用
`invalidatePlan` 将其转为 `Expired`，才能启动新计划或全额赎回；显式转换可防止旧拍卖
状态被重新绑定到新计划 nonce。

### 6.3 拍卖生命周期

```text
Idle -> Planned -> AuctionActive -> Planned -> Settled
                  \-> Expired / Cancelled -> Idle
```

- `Idle`：无可执行计划。
- `Planned`：目标和参考快照已固定；任何人可开有效的 surplus-to-deficit 拍卖。
- `AuctionActive`：一个资产对拍卖正在进行，可部分成交。
- `Settled`：达到 destination、耗尽换手预算，或已无 raw-unit 可执行资产对。
- `Expired` / `Cancelled`：安全执行不可得；池保留当前配置，等待后续计划。

拍卖结束后，在任何人调用 `expireAuction` 前仍保持生命周期锁；计划到期后，在任何人
调用 `invalidatePlan` 前仍保持生命周期锁。两个清理调用均无需许可、不移动资产，并防止
旧状态被静默覆盖。

每次出价按当前 Manager 储备和 live supply，使用 snapshot target raw / snapshot
supply 的完整精度比例重算 lot。因此即使低 decimals 与极大 share supply 并存，赎回
也不会导致归零目标或超额成交。

### 6.4 拍卖价格与 lot 限制

基金卖出资产为 `X`、买入资产为 `Y`，冻结参考报价 `P0` 的单位为 `Y per X` 时：

```text
Pstart = P0 * (1 + startPremium)
Pend   = P0 * (1 - maxDiscount)
P(t)   = linearInterpolate(Pstart, Pend, elapsed / duration)
```

首个竞拍者按当前价格成交，而不是其提交的最高支付额。每笔出价声明最大支付额；
不足当前价格即拒绝。成交量同时受剩余 `X` surplus 与 `Y` deficit 限制。

`maxDiscount`、期限、lot 限制与计划换手预算在计划创建后不可变。任何路径都不能
降低 `Pend`、延长计划或增加换手预算。

### 6.5 DEX 与 solver 参与

DEX 交易在托管边界外得到支持：做市商可在直接出价前后通过 DEX 对冲；未来经审计、
经治理启用的 solver 可提交受限 fill adapter；未来批量拍卖整合可在链下净额多个腿，
但每笔被接受结果仍须服从相同链上拍卖限制。

基金自身没有任意 DEX 执行权限，以防 router 升级、恶意 calldata 和授权滥用。

### 6.6 预言机保护

在创建计划和每次出价前，`OracleGuard` 必须验证：Chainlink 有效、新鲜且（适用时）
sequencer 健康；DEX TWAP 在配置窗口内有效；两个源偏差不超过
`maxOracleDeviationBps`；当前交易对价格处于活跃计划冻结参考带内。

任一条件失败时，开拍和出价均 revert。配置版本变化后任何人可 `invalidatePlan`；
瞬时价格源异常不授予公众取消权，只有 guardian 可取消配置仍有效的 Planned 或 AuctionActive 计划。
禁用资产会阻断 issue/plan/open/bid，但永远不阻断记录储备的比例赎回。

`quoteBid(poolId, auctionNonce, sellAmount)` 会重复执行可执行路径的暂停、生命周期、
配置、预言机、容量、到期、价格和换手检查，并返回同一区块 bid 将使用的精确 `buyAmount`。
receiver 为零和调用者指定的 `maxBuyAmount` 属于交易参数，在 bid 中单独检查。较低层的
`currentPrice` 与 `liveAuctionCapacity` 仅用于诊断。

## 7. 权限

| 角色 | 权限 | 明确不得做什么 |
| --- | --- | --- |
| Governance timelock | 批准资产、设置全局安全边界、批准未来 solver adapter | 逐池批准/拒绝、移动储备或绕过拍卖边界 |
| Guardian | 暂停申购和调仓；取消 Planned 或 AuctionActive 计划 | 解除暂停、改权重、出售资产、阻止赎回 |
| Risk admin | 通过治理流程提出 registry 与预言机更新 | 执行交易或设置自由裁量价格 |
| Pool creator | 用已启用资产建池、完成 bootstrap、发布本池有界政策 | 添加未批准资产、超过全局边界、移动储备或绕过政策延迟 |
| Public caller | 启动合格计划、开有效拍卖、出价、到期拍卖、使旧配置计划失效 | 改计划边界、取消安全拍卖或修改目标权重 |
| Share holder | 转让份额、按比例申购和赎回 | 除正常流程外影响拍卖价格或池储备 |

## 8. 安全不变量

1. 每份 share 都可兑换为当前记录储备的精确按比例索取权，除非标准 token 转账失败。
2. 目标权重和预言机值永远不决定普通 issue/redeem 数量。
3. Manager 对任一资产的聚合记录储备永不超过其实际 token 余额。
4. 除按比例赎回或已验证拍卖 fill 外，没有 token 可离开 Manager。
5. 拍卖不能卖出超过当前 surplus，也不能买入超过当前 deficit。
6. 拍卖价格不能对基金差于冻结的 `Pend` 边界。
7. 预言机分歧、过期或不安全价格变动会阻止执行。
8. 部分 fill 只能改善活跃计划的 deficit/surplus，不能产生未记账负债。
9. 暂停永远不能阻止按比例赎回。
10. 任意合约不能获得 Manager 资产授权或回调控制权。

## 9. 第一阶段合约清单

- `src/core/DemeterManager.sol`
- `src/core/AssetRegistry.sol`
- `src/core/IndexPolicy.sol`
- `src/core/AuctionRebalance.sol`
- `src/core/DemeterShare.sol`
- `src/core/DemeterBasketRouter.sol`
- `src/oracle/UniswapV3TwapOracle.sol`
- `src/interfaces/IDemeterManager.sol`
- `src/interfaces/IIndexPolicy.sol`
- `src/interfaces/IAuctionRebalance.sol`
- `src/interfaces/IAssetRegistry.sol`
- `src/interfaces/ITwapOracle.sol`
- `src/interfaces/IDemeterShare.sol`
- `src/libraries/PoolId.sol`
- `src/libraries/ProportionalMath.sol`
- `src/libraries/AuctionMath.sol`
- `src/libraries/OracleGuard.sol`
- `src/libraries/V2Errors.sol`

`DemeterVault`、`DemeterFactory`、旧 `DemeterRouter`、`VaultMath`、Aave adapter、
独立 circuit breaker、加权 AMM 数学和 passive trajectory 逻辑都仅是 legacy 参考。

## 10. 实施规则

在下列内容同时冻结在测试和文档中之前，不得编写生产核心合约：

1. 按储备比例的申购与赎回公式；
2. 支持资产政策和聚合储备会计；
3. 政策版本和计划状态布局；
4. 拍卖 lot、价格、到期和取消语义；
5. 双源预言机验证与过期价格行为；
6. 角色权限和紧急赎回行为；
7. 第 8 节的全部不变量。
