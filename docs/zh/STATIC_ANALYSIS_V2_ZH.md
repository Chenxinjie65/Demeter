# Demeter V2 静态分析分类

[English](../STATIC_ANALYSIS_V2.md)

> 工具：Slither 0.11.3；交叉检查：Aderyn 0.6.8
>
> 日期：2026-09-05
>
> 范围：V2 core、oracle、interfaces、types、libraries；过滤 legacy Vault/Factory/Aave/通用 Router、测试、脚本和依赖。

使用 `bash script/v2/check-slither.sh` 执行门禁。脚本使用 Slither 的 `--fail-high`，
每次运行都写入新的临时 JSON 报告。当前 V2 范围没有
Critical/High；Medium 及以下结果保留可见并逐项分类，而不是隐藏。

- `bid` 在 Manager 外部调用后写 fill：这是 Manager 读取 pre-fill auction 并执行防御性复核所必需。Manager 的全部资产操作共用同一个 `ReentrancyGuardTransient`，并只读暴露 guard 状态；plan start、policy activation、旧计划失效和 Guardian 取消在 token callback 中均失败。`bid` 在结算返回后再次核对 auction/plan 状态；issue、redeem、bid 均有 callback 定向测试。按当前支持资产模型判定为非可利用重入。
- 未初始化 accumulator/bool/`bytes32`：Solidity 自动零初始化，所有成功 reason 分支在 emit 前赋值，属于 false positive。
- enum/zero 严格相等、timestamp：对应精确状态、deadline、epoch 和 auction window 语义。
- loop 内外部读取：资产数量受全局 hard cap 32 和默认 16 限制，只读取固定协议依赖或已准入标准 token；仍需在目标链做 gas 门禁。
- Registry 零地址：通过 `_validateAddress`/`_validateContract` helper 检查，语法 detector 未跟踪 helper；定向测试覆盖。
- 忽略 Uniswap `observe` 的第二返回值：定价只需要 tick cumulatives；历史流动性由资产准入链下审查，属于有意行为。
- 复杂度和 ABI return name shadowing：当前函数执行完整风险校验且有单元/状态化测试；继续扩展 Auction 前应拆分纯计算模块。

Aderyn 的两类 High 已逐路径复核：`H-1 Reentrancy` 将固定依赖的 `STATICCALL` 与 token
转账后写状态一并报告；Manager 统一 transient guard、固定模块 guard 查询、bid 返回后
状态复核和 issue/redeem/policy/invalidation/cancel callback 回归测试已覆盖真实边界，
属于 detector 范围过宽。`H-2 Unprotected initializer` 把只读 getter
`initialPolicyHash` 按函数名误判为 initializer；该函数不写状态，属于 false positive。

本分类不替代独立安全审计。生产仍受 `RELEASE_CHECKLIST_V2_ZH.md` 中的审计、生产资产 fork 测试和治理角色检查阻塞。
