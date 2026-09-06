## Git 提交流程与提交信息规范

> 目标：让 Demeter 仓库的提交记录清晰、可读、可追踪，便于 Code Review 和后期维护。

---

### 1. 基本流程

- 每次开发前：
  - 从 `main`（或当前工作分支）拉取最新代码：`git pull`
  - 确保本地能成功编译 & 测试通过（至少跑核心测试）。

- 每次提交前：
  - 使用 `git status` 确认本次提交包含的改动范围合理、聚焦。
  - 不要把多个不相关的改动混在一个提交里（比如同时改 Solidity 合约和文档风格，最好拆成两个 commit）。

---

### 2. 提交信息格式（基于 Conventional Commits 轻量版）

**格式：**

```text
<type>(<scope>): <short summary>

<optional body>

<optional footer>
```

- **type**（必填，小写）推荐使用：
  - `feat`：新功能（feature）
  - `fix`：Bug 修复
  - `refactor`：重构（不改变外部行为的代码调整）
  - `docs`：文档相关改动（如 `docs/ARCHITECTURE_V2.md`、`COMMIT_GUIDELINES.md`）
  - `test`：测试相关（新增/修改 `test/` 下的内容）
  - `chore`：构建工具、依赖更新、CI 配置等杂项
  - `style`：代码风格（空格、格式化等），不影响逻辑

- **scope**（可选，建议使用）：
  - 用于说明影响的模块，例如：`core`, `vault`, `factory`, `oracle`, `address-provider`, `docs`, `scripts`
  - 如果不想写 scope，也可以省略括号，直接写 `feat: ...`

- **summary**（必填）：
  - 简短的一句话（英文或中英混合均可），概括本次提交做了什么。
  - 不需要句号，建议 50 字符以内，使用祈使句，例如：`add`, `fix`, `update` 开头。

**示例：**

```text
feat(core): add DemeterVault storage layout with ERC-7201

fix(oracle): enforce max stale time for chainlink feeds

docs: update architecture diagram and role descriptions

refactor(address-provider): rename factory getter to getFactory

test(vault): add fuzz tests for deposit/withdraw math
```

---

### 3. 提交粒度建议

- **一个功能 / 一个 bug 修复 = 至少一个独立提交**
  - 例如：
    - `feat(core): implement ProtocolAddressProvider`
    - `test(core): add unit tests for ProtocolAddressProvider`

- **大功能可以拆成多步提交**：
  - 先提交接口定义：`feat(interfaces): add IDemeterVault and IDemeterFactory`
  - 再提交实现骨架：`feat(core): scaffold DemeterVault and DemeterFactory`
  - 最后提交测试与完善：`test(core): add basic vault/factory tests`

- **避免“大杂烩”提交**：
  - 若同时修改多处无强关联的内容（例如 增加功能 + 大量格式化），尽量拆成两个 commit，方便 review 和回滚。

---

### 4. 常见场景示例

- **新增合约或模块：**

```text
feat(core): add ChainlinkOracle implementation
```

- **修复重入或安全问题：**

```text
fix(vault): add nonReentrant guard to deposit and withdraw
```

- **仅改注释 / 文档：**

```text
docs: clarify upgrade model for DemeterVault and AddressProvider
```

- **更新依赖或 Foundry 配置：**

```text
chore: bump openzeppelin-contracts to v5.1.0 and update remappings
```

---

### 5. 提交前检查清单

在执行 `git commit` 前，建议快速自查：

- 代码可以正常编译（`forge build` / `forge test` 至少跑一遍核心测试）。
- 没有意外提交的临时文件（如 `.env.local`、IDE 配置、编译产物等）。
- 提交信息符合上述格式，能让几天后的自己/他人“一眼看懂”这次改了什么、为什么改。

