# Demeter V2 事故处置手册

[English](../INCIDENT_RUNBOOK_V2.md)

> 状态：承载真实 AUM 前的运维前置条件。
>
> 修订日期：2026-09-05

## 1. 安全优先级

1. 保持比例赎回和 Manager 储备记账正确；
2. 价格或 token 安全不确定时，停止新申购与调仓执行；
3. 修改配置前保留链上证据；
4. 恢复配置必须走 Timelock；Guardian 只能暂停和取消活跃计划。

事故处置不得临时加入 DEX 任意调用、宽泛 token 授权、代理升级或赎回暂停。

## 2. 角色

| 角色 | 可立即执行 | 禁止执行 |
| --- | --- | --- |
| Guardian | 暂停 Auction 路径，取消 Planned/AuctionActive 计划 | 解除暂停、改 feed/权重、移动储备 |
| Timelock 治理 | 禁用资产、轮换 Guardian、更新有界配置、解除暂停 | 绕过延迟或逐池自由交易 |
| 公众 keeper | 到期拍卖、使过期或版本失效计划失效 | 取消仍有效计划 |
| Operator/indexer | 告警、保留交易/预言机证据、发布状态 | 签署特权交易 |

## 3. 告警信号

- `manager.tokenBalance(asset) < manager.accountedReserve(asset)`；
- Chainlink 过期、轮次不完整、非正值，或 sequencer 中断；
- Chainlink/TWAP 分歧或参考价格变动超过上限；
- 计划/拍卖超过期限仍保持 active；
- 非预期的资产、全局政策、family、Guardian、pause/unpause 事件；
- 连续成交失败、实际折价接近 `Pend`、竞拍者过度集中；
- token proxy/实现、转账语义、decimals 或发行方状态发生变化。

## 4. 立即响应

1. 记录 chain ID、block、pool ID、plan/auction nonce、相关交易、Manager 余额与储备、
   feed round、TWAP observation 和配置版本；
2. Guardian 调用 `AuctionRebalance.setPaused(true)`，阻断 issue/start/open/bid；赎回继续；
3. 活跃计划由 Guardian `cancelPlan`；仅到期或版本失效时由任意 keeper 调用
   `expireAuction` / `invalidatePlan`；
4. 资产/feed/pool 可疑时，通过 Timelock 安排禁用或修正；不得临时换成未经审查的源；
5. 公告受影响路径、池和资产，并明确 in-kind 赎回仍取决于 token 本身可转账。

## 5. 场景流程

### 预言机分歧或 sequencer 中断

双源恢复且 grace period 结束前保持暂停。配置仍有效的计划只能由 Guardian 取消；瞬时
oracle revert 不能作为公众失效理由。新计划必须使用新鲜双源快照。

### Token 行为变化或脱锚

先暂停，再由 Timelock `disableAsset`。禁用会阻断 bootstrap/issue/plan/open/bid，但不
阻断记录储备的比例赎回。对外说明前核对 Manager 实际余额。负 rebase 或发行方冻结是
外部资产故障，不能用虚假会计修复。

### 储备覆盖告警

不得解除暂停。按告警 block 复算，区分非请求 surplus、transfer/rebase 损失或监控错误。
Surplus 不归属任何池；deficit 必须独立复核并制定治理批准的迁移/补救方案，禁止静默改账。

### 拍卖卡住或无成交

`endTime` 后由任意 keeper `expireAuction`；plan 到期后 `invalidatePlan`。不得延长曲线、降低
`Pend` 或覆盖旧 nonce。新计划前复核 lot、外部流动性和 bidder 对冲成本。

### Guardian 泄露

Timelock 安排 `AssetRegistry.setGuardian(newGuardian)`。Guardian 只能暂停和取消计划，不能
解除暂停、改政策或移动资产；复核暴露窗口内所有 pause/cancel 事件。

### 核心缺陷

V2 核心不可升级。保持受影响路径暂停，部署经审查的新版本，并另行规定 Timelock 迁移。
不得臆造对 immutable Manager 的迁移调用；迁移需要新架构决策、实现、测试与审计。

## 6. 恢复门禁

解除暂停前必须：逐资产对账；生产 Chainlink/TWAP/sequencer fork 检查通过；显式清理旧
计划/拍卖；复核根因与配置 diff；补充监控及回归测试；公告剩余外部风险。随后执行
`RELEASE_CHECKLIST_V2_ZH.md` 的确定性命令。任何代码或信任边界变化都必须重新外审。
