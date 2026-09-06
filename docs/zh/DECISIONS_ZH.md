# Demeter 架构决策记录

[English](../DECISIONS.md)

> 说明：DEC-001 至 DEC-012 记录旧 Factory/Beacon/Vault 原型的历史决策，保留
> 供排错参考，不是 V2 规范。DEC-013 及以后记录 2026-08-31 批准的 V2 指数基金
> 架构。

## DEC-001 - 反 ERC-4626：同类资产篮子

**状态：** V2 中保留，但改为按实际储备比例。

ERC-4626 的单一基础资产分母会引入预言机延迟套利、强制兑换滑点和用户激励错位。
Demeter 使用全篮子 in-kind 申购和赎回；用户不必把资产转换成单一 base asset。
Router 可提供单币 UX，但不改变 Manager 的篮子会计。

## DEC-002 - EIP-1153 瞬态记账

**状态：** 旧实现历史参考，V2 第一阶段延后。

旧设计用 transient storage 记录单笔操作的资产 delta。V2 第一阶段的比例申赎和
直接拍卖结算采用显式 checks-effects-interactions；只有未来经过审计的 solver 多腿
结算才可重新引入 lock/callback/flash accounting。

## DEC-003 - 虚拟偏移与 dead shares

**状态：** 旧 vault 历史参考，不直接用于 V2。

V2 的首次 bootstrap 使用批准的种子篮子与确定的初始份额供应。正式 issue/redeem
使用 `ceil`/`floor` 的储备比例公式，不复制旧的 AUM 虚拟偏移公式。

## DEC-004 - Beacon、UUPS 与 Transparent Proxy

**状态：** V2 否决所有核心代理。

旧原型选择 BeaconProxy 以统一升级 vault。V2 的 Manager、Share、Policy、Auction
和 Registry 都不使用 proxy；缺陷通过暂停、部署新版本和受控迁移处理。基金托管
核心不承担可升级实现的存储碰撞和治理升级风险。

## DEC-005 - Aave 10% buffer

**状态：** V2 延后外部收益策略。

旧 vault 保留 10% idle buffer 以防 Aave 无法提款。V2 第一阶段不接入 Aave、staking
或其他收益部署，避免第三方协议流动性和会计复杂度进入基础基金。

## DEC-006 - 舍入方向

**状态：** V2 保留并明确化。

issue 所需资产向上舍入，redeem 输出向下舍入：

```text
requiredIn[i] = ceil(reserve[i] * sharesOut / totalShares)
amountOut[i]  = floor(reserve[i] * sharesIn  / totalShares)
```

任何舍入 dust 必须归属于储备，且不能成为重复申赎的可提取价值。

## DEC-007 - 每 vault 一个 Aave adapter

**状态：** 仅旧实现历史参考，V2 不使用。

该决定修复了 Aave aToken 所有权问题，但 V2 第一阶段没有外部收益 adapter。未来
引入收益策略必须形成新的架构决策、权限模型和独立审计范围。

## DEC-008 - CircuitBreaker finalizeVault

**状态：** 仅旧 Factory 原型历史参考。

V2 不部署旧的 standalone CircuitBreaker。Guardian 在 Manager/ AuctionRebalance
中只能暂停申购、计划和拍卖，不能阻止按比例赎回。

## DEC-009 - 初始化时连接 CircuitBreaker

**状态：** 仅旧实现历史参考。

V2 的一次性地址连接通过 Manager、Policy、Auction 和 Registry 的 immutable 构造参数
及首池创建前的一次性 auction authority 设置完成，不使用旧 vault initializer wiring。

## DEC-010 - 旧 vault fee 收集时机

**状态：** 仅旧实现历史参考。

V2 第一阶段不加入管理费和绩效费。费用若未来加入，必须作为独立模块和新决策设计，
且不能改变按比例申赎储备公式。

## DEC-011 - 旧部署器角色默认值

**状态：** V2 否决。

V2 生产部署必须从第一笔有价值交易起使用 Timelock、Guardian 和明确的角色配置，
不能把 deployer 作为长期全权角色。

## DEC-012 - 旧 CircuitBreaker 默认无限额度

**状态：** V2 不适用。

V2 不允许使用“有效无限”的生产风险参数。每个 auction plan 的折价、lot、期限和
换手预算都必须明确、有界并在创建后不可扩大。

## DEC-013 - 指数基金，而不是管理型 AMM

**日期：** 2026-08-31；**状态：** V2 正式决策。

否决通过改变 Balancer 权重让套利者被动调仓的方案。改变 AMM 权重会改变基金报价，
基金持有人成为套利让价的库存提供者。Demeter 是指数基金：持有篮子、发行按比例
索取权，并只通过有界拍卖调仓。

## DEC-014 - 按实际储备比例申购和赎回

**日期：** 2026-08-31；**状态：** V2 正式决策。

否决 oracle NAV 定价和按目标权重强制入金。普通 issue/redeem 只读取 Manager 记录
的实际储备与份额供应。目标权重、Chainlink 和 TWAP 只用于调仓计划和保护边界。

## DEC-015 - Epoch-Banded 荷兰拍卖

**日期：** 2026-08-31；**状态：** V2 正式决策。

否决 Manager 直接 DEX、TWAP 切片、渐变 AMM 和 solver-only 方案。V2 使用政策 epoch
与漂移双阈值产生固定计划，再以起始溢价到最大折价的有界荷兰拍卖执行。拍卖公开、
可部分成交、过期后不强制低价成交。solver 只能作为未来经审计的受限 fill adapter。

## DEC-016 - Chainlink 主锚 + 外部 DEX TWAP 保护

**日期：** 2026-08-31；**状态：** V2 正式决策。

Chainlink 是主要 USD 价值锚和资产准入条件；外部、非 Demeter 池的 DEX TWAP 是独立
交叉检查。计划创建和每次 bid 前，两个来源都必须新鲜、有效且偏差在配置范围内。
拍卖冻结参考价 `P0`，预言机分歧或价格超出变动带时停止出价，而不是连续跟随预言机
改价。预言机永远不用于普通 issue/redeem。
后续配置版本失效可由任何人公开使计划失效；瞬时预言机异常只阻断出价，Guardian
可取消 Planned 或 AuctionActive 计划。

## DEC-017 - 稳定池身份与不可变资产列表

**日期：** 2026-08-31；**状态：** V2 正式决策。

`poolId` 只由 `chainId`、Manager、creator、资产顺序、policy family 和 creator salt
派生。creator 绑定所有权并防止 mempool 复制抢占。目标权重、
费用、预言机参数、政策版本和 share 地址均排除。Manager 先派生 ID，再用 CREATE2
部署 share。资产成分变化必须迁移到新池。

## DEC-018 - 第一阶段不强制 lock/callback 核心

**日期：** 2026-08-31；**状态：** V2 正式决策。

比例 issue/redeem 和直接 ERC-20 bid 不需要任意回调或 transient delta。第一阶段使用
简单、可审计的原子转账；仍使用 OpenZeppelin transient reentrancy guard 作为 Manager
资产操作互斥锁，该 guard 不开放 callback，也不记录结算 delta。通用
lock/callback/flash accounting 只保留为未来多腿 solver 结算的候选工具，不能扩大
Manager 的资产调用面。

## DEC-019 - 不使用代理，采用不可变核心与受限配置

**日期：** 2026-09-01；**状态：** V2 正式决策。

`DemeterManager`、`DemeterShare`、`AuctionRebalance`、`IndexPolicy` 和
`AssetRegistry` 均不使用 proxy。核心依赖在构造时 immutable，或由 Manager 在首池前
一次写入后永久冻结；需要修复时暂停旧路径、部署新版本并进行治理迁移。可变的
资产/预言机配置只能由 Timelock 修改，并带配置版本。

## DEC-020 - AssetRegistry，而不是万能 AddressProvider

**日期：** 2026-09-01；**状态：** V2 正式决策。

V2 使用职责受限的 `AssetRegistry` 记录资产 decimals、Chainlink feed、外部 TWAP
池、窗口、偏差和角色。Manager、Policy、Auction 的关键依赖尽量 immutable，不允许
通过一个万能地址表动态替换任意执行模块。预言机配置变化递增版本；旧计划引用旧
版本并自动失效，必须重新创建价格快照。

## DEC-021 - ERC-20 基金份额

**日期：** 2026-09-01；**状态：** V2 正式决策。

虽然 ERC-6909 能在单例内按 ID 管理多种份额，但基金份额需要钱包、DEX、借贷协议
和聚合器的现成 ERC-20 兼容性。Demeter 保留每池独立 ERC-20 `DemeterShare`；未来
若需要单例内部优化，可另行研究 ERC-6909，但不得在没有迁移方案前改变外部份额标准。

## DEC-022 - 在全局边界内无需许可创建池

**日期：** 2026-09-01；**状态：** V2 正式决策。

任何地址都可以基于 `AssetRegistry` 已启用的资产集合创建自己的指数基金，无需 DAO
逐池批准。创建者提交不可变资产顺序、share 元数据、bootstrapper 和 policy family，
并在协议全局的资产数量、权重、换手、拍卖参数和预言机安全边界内初始化池。

无需许可不等于任意 token 或任意参数：未启用资产仍被拒绝，只有治理 timelock 能
修改全局风险边界。创建者可以为自己的池发布带延迟的政策版本，但不能修改资产列表、
移动储备或绕过 `effectiveAt`。

Pool creation 提交每项非零 seed、初始 share supply、recipient、bootstrapper、deadline
和初始 policy hash。只有记录的 bootstrapper 可触发；标准 ERC-20 allowance 不绑定
poolId，放开 relayer 会产生跨池盗用风险。Manager 只从该账户精确拉取。
活跃 plan 阻止全额赎回；其他情况下全额赎回将池永久标记为 `closed`。

policy hash 是 creator commitment，不是逐池 timelock 批准。`MANAGED_INDEX` 与
`IMMUTABLE_INDEX` 创建时固定，只有 managed 可追加 creator policy。

多资产池对同一个 common quote asset 观察 TWAP，`X/Y` 由两条共同报价观察之比得到；
第一阶段不支持任意 direct pair 或未经审查的 multi-hop。

资产或相关配置禁用/更新后，旧计划可由任何人失效；issue/plan/open/bid 被阻断，但
现有池仍可赎回记录储备。瞬时预言机异常仅阻断交易，Guardian 才能无条件取消计划。

## DEC-023 - 精确快照目标与统一计划缩放

**日期：** 2026-09-02；**状态：** V2 正式决策。

否决以 `1e18` 精度保存每份额目标并独立裁剪每项资产差额：低 decimals 资产配合极大
share supply 会把目标舍入为零，独立裁剪还可能生成总价值不守恒、无法由 surplus
覆盖的 deficit。

计划改为保存 target raw amounts 与 snapshot share supply；live target 使用
`mulDiv(targetRaw, liveSupply, snapshotSupply)`。全部资产差额使用同一缩放因子，同时
满足逐资产和总换手上限，再以舍入后的实际买卖名义量确定预算。风险换手向上取整，
防止拆分 fill 低估消耗。跨计划最大速率由 `maxTurnoverBps + minPlanInterval` 约束，
第一阶段不保存独立 rolling-window 累加器。

## DEC-024 - 公众使旧计划失效，Guardian 取消有效计划

**日期：** 2026-09-02；**状态：** V2 正式决策。

否决“任何 oracle revert 都允许公众取消”：caller 可故意限制 gas 或利用瞬时依赖故障，
反复取消本来安全的拍卖。任何人只有在资产/oracle/policy family/global bound 固定版本
不匹配或计划过期时，才可调用 `invalidatePlan`。开拍和 bid 在瞬时异常时直接 fail
closed。Guardian 可对 Planned 或 AuctionActive 调用 `cancelPlan`，但不能改目标或移动
资产；所有情况下 redeem 均保持可用。

## DEC-025 - 固定模块共享 Manager 操作 Guard

**日期：** 2026-09-04；**状态：** V2 正式决策。

否决“仅依赖每个合约自己的 `nonReentrant` 与治理排除 callback token”：Manager 转账时，
Auction 可能仍需在结算返回后写状态。callback 虽不能重入 Manager，却可调用另一个合约
中无需许可的 Policy/Auction 生命周期入口，从而在 issue 中启动计划、在 fill 中激活新
政策，或在 Auction 写入 fill 前取消/失效计划。

Manager 的所有资产操作统一使用 OpenZeppelin transient reentrancy guard，并只读暴露
guard 状态：生效期间 `isPoolActive` 为 false、`isOperationActive` 为 true。固定 Policy 与
Auction 模块在此期间拒绝政策激活、计划创建、旧计划失效及 Guardian 取消；`bid` 在
Manager 结算返回后还会复核 plan/auction active 状态。这只是窄化的协调信号，不是通用
callback API，也不授予任何移动资产权限。

生产资产门禁仍排除 callback 和 balance-changing token；对抗性 token 测试额外证明，
callback 无法在检查与结算之间改写生命周期状态或铸造份额。

## DEC-026 - 取消仍保持 append-only 与首发 AUM 控制

**日期：** 2026-09-05；**状态：** V2 正式决策。

尚未激活的政策可以由 creator 取消，或在固定配置过期时由公众失效，但取消不能删除
已发布的版本。尤其是取消初始 version 1 后，其 hash 和版本记录仍保留；池不能重新发布
version 1，只能保持不可 bootstrap 状态直至 bootstrap deadline 到期。这样保留事件历史，
并满足政策版本 append-only 不可改写不变量。

首版 AUM 上限是运营启动控制，而不是依赖预言机的链上硬上限。`issue` 继续在批准资产
集合内按储备比例无需许可执行；把 USD 硬上限加入申购路径会新增价格依赖。生产启动时采用
书面的小 AUM 软上限、监控和基于成交质量/流动性证据的治理提升规则。若要宣传硬上限，
必须另行做出设计决策并补充测试。
