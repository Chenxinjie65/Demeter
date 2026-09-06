# Demeter 调仓白皮书

[English](../REBALANCING_WHITEPAPER.md)

> 状态：Demeter V2 正式经济与执行规范。
>
> 修订日期：2026-09-05
>
> 产品定位：链上指数基金，不是公开 AMM 流动性池。

## 1. 目的

本文定义 Demeter 如何维护已发布的指数配置，同时避免把全部篮子变成 AMM
库存。目标不是最大化短期收益，而是在明确执行成本、权限和失败模式的前提下
控制指数跟踪误差。

Demeter 采用 **Epoch-Banded Auction Rebalance（分 epoch、有界拍卖调仓）**：

1. 池 creator 在治理全局边界内发布透明的目标权重政策版本；
2. 日历事件和漂移区间决定何时允许计划；
3. 新鲜的双源价格快照决定有界拍卖限制；
4. 公开竞拍者竞争性地将超配资产换成低配资产；
5. 部分成交或失败只留下公开的跟踪误差，不会无限扩大让价。

## 2. 基金会计基线

对 `n` 个资产：

- `q[i]`：基金记录储备中的资产 `i` 数量；
- `p[i]`：经过验证的资产参考价格；
- `V = sum(q[i] * p[i])`：参考组合价值；
- `N`：基金份额总供应；
- `w[i]`：发布的目标价值权重，且 `sum(w[i]) = 1`；
- `a[i] = q[i] * p[i] / V`：实际价值权重。

漂移使用总变差距离：

```text
D(a, w) = 1/2 * sum(abs(a[i] - w[i]))
```

不调仓的 buy-and-hold 组合是强制基准。任何调仓机制只有在暴露控制收益足以
覆盖执行成本与残余风险时才可接受。

普通 issue/redeem 不使用 `p` 或 `w`：

```text
issue:  in[i]  = ceil(q[i] * sharesOut / N)
redeem: out[i] = floor(q[i] * sharesIn  / N)
```

第一阶段只提供 in-kind `DemeterBasketRouter`。预言机定价的单币申购需要独立审查，
不是基金核心会计操作。

## 3. 为什么否决 AMM 调仓

加权 AMM 改变权重时会改变边际报价，套利者随后交易池子以恢复外部价格。这对
做市池或 LBP 有用，但意味着基金持有人为套利调整提供库存和经济让价。

基金承担的不是单纯可见 swap fee，还包括逆向选择和不变量重定价损失。Demeter
此前研究模型将这部分标记为隐性损失，历史结果也表明 passive swap 和 passive
damped 的表现高度依赖参数及市场状态。因此它们只能作为被否决方案的对照，不
能作为生产默认方案。

Demeter 不使用：

- 针对基金储备的公共 `swap()`；
- 改变基金内部交易曲线的 effective weights；
- 以方向性 swap fee 作为主要调仓激励；
- 连续的 `wPath -> wEffective` 迁移。

## 4. 历史执行模式比较

### 4.1 直接 DEX 执行

早期链上指数系统通常让有权限的 manager 通过 DEX adapter 交易篮子。它在流动性
充足时收敛快，但需要外部调用、token 授权、路由 calldata、滑点限制和持续维护
venue 集成。执行质量最终依赖 manager 与路由器假设。

适用：有可信或白名单执行者的主动管理 vault。

Demeter 第一阶段不采用：共享托管 Manager 不应拥有任意外部调用权限。

### 4.2 TWAP 切片 DEX 执行

把大单拆分可降低瞬时冲击，但会暴露可预测的未来订单流、需要 keeper，并让每个
切片都承受 MEV。它适合必须及时维护杠杆的风险策略，不适合被动指数基金默认调仓。

### 4.3 渐变权重 AMM

Balancer 式渐变权重让价格随时间移动，再由交易者套利回外部价格。它适合 LBP
和管理型流动性池，但主动把 LP 库存暴露给公开交易，因此不符合基金定位。

### 4.4 荷兰拍卖

荷兰拍卖以已知数量的超配资产换取低配资产，价格从对基金有利的位置下降到预先
批准的最差价格。任何做市商、bot、聚合器或 solver 都能竞争成交。它不需要 Manager
批准 DEX，且让价透明、有界，因此是 Demeter 的选择。

### 4.5 Batch solver 与 RFQ

批量 solver 能净额多条腿并发现统一清算价，RFQ 可从专业做市商取得报价。它们是
未来的竞拍者或受限 fill adapter，不应在基础基金机制尚未证明前成为不可替换依赖。

## 5. 触发策略

触发策略决定“是否交易”，拍卖策略决定“如何交易”，两者必须分离。

### 5.1 结构性政策 epoch

政策 epoch 经 `effectiveAt` 延迟后才能改变目标权重。creator 选择目标向量，但必须
满足 governance timelock 设置的全局边界，且不包含可直接执行价格。
`IMMUTABLE_INDEX` 只接受初始政策；`MANAGED_INDEX` 才允许记录的 creator 发布后续版本。

### 5.2 漂移区间

当实际组合偏离政策达到触发值且满足最小间隔时，才允许
漂移计划：

```text
D(a, w) >= trigger
now >= lastPlan + minInterval
```

执行到 `destination` 即停止，其中 `0 <= destination < trigger`。这条滞回带避免
在目标附近反复支付交易成本。

### 5.3 换手限制

```text
T = 1/2 * sum(abs(qTarget[i] - q[i]) * p[i])
```

每个计划都受单资产最大调整、计划总换手和计划最小间隔限制。第一阶段不保存独立
rolling-window 累加器；`maxTurnoverBps + minPlanInterval` 推导最大换手速率。超过
上限时只执行统一缩放后的第一步，不静默修改政策目标。

## 6. 分 epoch 有界拍卖调仓

### 6.1 计划形成

计划启动者取得新鲜的双源参考价格，计算：

```text
qTarget[i] = V * w[i] / p[i]
surplus[i] = max(q[i] - qTarget[i], 0)
deficit[i] = max(qTarget[i] - q[i], 0)
```

计划记录政策版本、nonce、target raw amounts、snapshot share supply、冻结价格和时间、到期时间、换手预算、
单资产限制、预言机偏差和冻结参考变动带、起始溢价、最大折价及拍卖时长。

计划是风险边界，不保证达到精确目标。

### 6.2 开拍与 lot

任何人都可从当前 surplus 资产 `X` 和 deficit 资产 `Y` 中开一场有效拍卖。第一版
每池同一时间只允许一场。每笔 bid 都根据最新记录储备、份额供应和 snapshot target
raw/supply 的完整精度比例重新
计算 lot，并同时受计划限制。

### 6.3 价格曲线

冻结报价 `P0` 的单位是 `Y per X`：

```text
Pstart = P0 * (1 + startPremiumBps / 10_000)
Pend   = P0 * (1 - maxDiscountBps  / 10_000)
P(t)   = Pstart - (Pstart - Pend) * elapsed / duration
```

基金出售 `X` 时必须至少收到当前 `P(t)` 数量的 `Y`。竞拍者提交最大支付额，成交
按当前价格执行，且不能超过剩余 surplus、deficit 或计划换手预算。

拍卖一旦打开，曲线不可改变；任何角色都不能降低 `Pend`、延长时长或增加 lot/预算。

### 6.4 部分成交与到期

每次成交都原子更新储备并重新计算剩余 lot。部分成交是正常结果。拍卖结束后，任何人
可调用 `expireAuction`；如果计划期限仍有效，计划回到 Planned，否则转为 Expired。计划
期限结束后，任何人可调用 `invalidatePlan` 释放生命周期锁。显式清理不移动资产，也防止
旧拍卖状态绑定到新计划。基金保留当前配置，部分赎回始终可用，不会被迫以更差价格成交。

## 7. 双源预言机设计

| 来源 | 职责 | 不用于 |
| --- | --- | --- |
| Chainlink USD feed | 主价值锚与资产准入 | 直接 issue/redeem 定价 |
| 外部 DEX TWAP | 每资产/common-quote 独立校验与市场异常信号 | Demeter 自身池的自引用 |
| 拍卖曲线 | 实际成交价格 | 无界市场预言机 |

每项非共同报价资产需要批准的 asset/common-quote TWAP 池；共同报价资产使用 Chainlink
USD 值作为 numeraire，不配置 quote/quote 池。`X/Y` 由两条共同报价观察之比得到，
并与独立 Chainlink 比值交叉检查。计划创建、开拍和每笔 bid 前验证 Chainlink 为正值、完整、新鲜且
sequencer 正常；TWAP 窗口有效；双源偏差不超过上限；当前价格仍位于冻结参考带。
任一条件失败时交易 revert。配置版本变化后任何人可 `invalidatePlan`；瞬时价格异常
时只有 Guardian 可无条件取消 Planned 或 AuctionActive 计划。

Chainlink 可能相对快速市场延迟，DEX spot 可操纵，TWAP 也可能滞后或失去代表性。
双源一致并不能消除风险，但能把风险转化为安全的 no-trade 状态。拍卖冻结 `P0`，
而不是跟随预言机连续改价；后者会重新制造更难审计的动态做市商。

`quoteBid(poolId, auctionNonce, sellAmount)` 会重复执行 bid 的暂停、生命周期、配置、
预言机、容量、到期、价格和换手检查，并返回同一区块 bid 将使用的精确支付额。bid 的
receiver 与调用者指定的最大支付额仍在交易中单独检查；较低层的价格与容量查询仅用于诊断。

## 8. DEX 与 solver 支持

DEX 仅在托管边界外提供流动性：竞拍者可在出价前后对冲，做市商可链下聚合多个
venue，未来 solver 可通过审计过的受限 adapter 提交 fill。Manager 永远不暴露
任意 calldata 或广泛授权；solver 故障不能阻止直接竞价或赎回。

## 9. 成本与验收指标

每笔完成的 fill 至少报告：

```text
executionCost = referenceValueSold - referenceValueReceived
fillDiscount  = (P0 - executionPrice) / P0
turnover      = referenceValueSold
```

同时记录成交时间、未成交名义金额、计划后漂移、预言机分歧、竞拍者集中度，并与
buy-and-hold 和直接 DEX 模拟比较。提高 AUM 上限前必须有真实 lot 下的成交质量和
冲击证据，不能只依靠有利回测。

## 10. 权限与安全边界

- Governance timelock 设置资产集合和硬执行边界，pool creator 发布自己的有界政策；
- Guardian 可暂停申购和调仓、取消 Planned 或 AuctionActive 计划，但不能解除暂停、改权重、移动储备或阻止赎回；
- Risk admin 只能通过治理流程提出 Registry/预言机变更；
- Public caller 可启动计划、开拍、出价、到期拍卖并使旧配置计划失效，但不能改边界或取消安全拍卖；
- 禁用资产阻断 issue/plan/open/bid，但绝不阻断记录储备的比例赎回；
- 第一阶段不允许半可信 launcher 在治理范围内自行选择对自己有利的价格。

## 11. 研究任务

上线前模拟器必须加入日内价格、波动率、预言机延迟、开拍延迟、部分/零成交、竞拍者
对冲成本、gas、Chainlink/TWAP 分歧、AUM 缩放 lot 和单一资产流动性消失等压力场景。

该方法只是针对“有界透明成本、公开竞争、无任意 Manager 交易权限”目标的相对优选，
不声称在所有市场状态下都优于 buy-and-hold 或其他执行方式。

## 12. 参考资料

- [Index Coop：Introducing Auction Rebalancing](https://www.indexcoop.com/blog/introducing-auction-rebalancing)
- [Reserve Index Protocol：Rebalance Lifecycle](https://docs.reserve.org/reserve-index/rebalancing/4-0-0)
- [Balancer：Liquidity Bootstrapping FAQ](https://balancer.gitbook.io/balancer/smart-contracts/smart-pools/liquidity-bootstrapping-faq)
- [Vanguard：The Rebalancing Edge](https://corporate.vanguard.com/content/dam/corp/research/pdf/the_rebalancing_edge_optimizing_target-date-fund-rebalancing-through-threshold-based-strategies.pdf)
