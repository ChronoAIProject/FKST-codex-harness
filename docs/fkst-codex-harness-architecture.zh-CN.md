<div align="center">

[![English](https://img.shields.io/badge/English-8b949e?style=for-the-badge)](fkst-codex-harness-architecture.md)&nbsp;[![简体中文](https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-1f6feb?style=for-the-badge)](fkst-codex-harness-architecture.zh-CN.md)

</div>

# fkst-codex-harness — 规格说明

`fkst-codex-harness` 仓库的精确规格说明：结构、packages、配置、依赖，以及将其
搭建运行所需的一切。与 `repo-architecture.md` §0 中锁定的决策保持一致
（**packages 位于本仓库；不做 PRODUCT/HOST 拆分**）。

*状态：设计阶段。截至 2026-06-30。数据依据：`codex-contribution-playbook.md`、
`METHODOLOGY.md`、`pilot-results.md`。*

---

## 1. 目的与约束

一个自主运行、本地部署的工具（harness），用于发现高价值的 `openai/codex` issue，
在 fork 上诊断并修复它们，然后**仅在受邀时**将其回提。

| 约束 | 后果 |
|---|---|
| Codex **仅限受邀**；未受邀的 PR 会被关闭 | 上游 = **读取 + 受门槛限制的提议（gated-propose）**，绝不自动写入 |
| 284 个已合并 PR 中有 283 个来自受信任的贡献者 | 优化**受邀率 + 自修复路径**，而非 PR 数量 |
| “重要性” = 由关联 PR 修复（fixed-by-linked-PR） | 候选项评分以修复率评分标准（rubric）为依据 |
| 我们**不拥有** openai/codex | **fork** 是唯一可写的代码面 |
| FKST = **能力安全（capability-secured）的本地引擎** | 按设备运行 `supervise`；gh/codex/git 作为计量边界 |
| FKST 原则：**状态只来自程序** | 不提交状态；durable 存储 + GitHub 标记；小载荷（small payloads） |

三个仓库（见 `repo-architecture.md`）：**fork**（仅代码）·**`fkst-codex-harness`**
（本仓库——packages + 配置 + 数据 + saga（事务流程）状态）·**`fkst-substrate`**（引擎 → BIN）。

---

## 2. 仓库布局（精确）

`fkst-codex-harness` 是一个**自托管的 Lua package 仓库**：它在顶层 `packages/` 中
拥有自己的 packages，并针对 codex 目标运行自身（`supervise`）。

```
fkst-codex-harness/
  packages/                              # ← CODEX PACKAGES 就位于此处
    codex-triage/
      core.lua                           #   共享的纯逻辑（可被 require）
      raisers/issues.lua                 #   轮询 openai/codex issue → 触发 codex_candidate
      departments/score_dedup/main.lua   #   应用评分标准（rubric）+ 聚类 → attemptable
      locales/en.lua                     #   t(key) 文案目录
      fkst.toml                          #   kind = "package"
      tests/*_test.lua
    codex-saga/
      core.lua
      departments/diagnose/main.lua      #   在 fork 上复现 + bisect + 定位根因
      departments/dossier/main.lua       #   讲述（先例）+ 推送 demo 分支
      departments/gate/main.lua          #   共识 + 受邀前置条件 + 上限
      departments/engage/main.lua        #   在 openai/codex 上执行 gh issue/comment
      departments/open_pr/main.lua       #   gh pr create fork→上游 + CLA
      raisers/invite_watch.lua           #   轮询 issue 以获取维护者邀请
      locales/en.lua
      fkst.toml                          #   kind = "package.composed", persistence_class = "saga",
                                         #   [event_deps] packages = ["codex-triage"]
      tests/*_test.lua
  libraries/                             # 可选的共享 Lua 库（contract/workflow 风格）
  data/                                  # 种子语料（通过 source_ref 读取，绝不内联进载荷）
    area_rubric.json
    open_issue_clusters.json
    worked_on_full.jsonl
  .fkst-substrate-ref                    # PIN：引擎源（fkst-substrate SHA/tag）
  fkst.workspace.toml                    # manifest 工作区；仅在复用 trio 时才 pin fkst-packages
  fkst.lock                              # 锁定任何外部（trio）源
  .fkst/
    env.example                          # 纳入版本控制的配置模板（§4）
    env                                  # 被 gitignore，按设备
    runtime/ durable/                    # 被 gitignore 的引擎临时区 + 状态
  scripts/run.sh                         # 来自脚手架 —— 委托给 host-run（不复制）
  scripts/check_repo.py                  # 来自脚手架
  .github/workflows/ci.yml               # 来自脚手架
  README.md  CLAUDE.md  LICENSE  .gitignore
  docs/                                  # 本规格 + 发现/方法论/试点
```

脚手架文件（`scripts/run.sh`、`scripts/check_repo.py`、`.github/workflows/ci.yml`、
`env.example`、`.fkst-substrate-ref`、`.gitignore`、`README.md`）由
`fkst-framework init-package-repo` 生成 —— 请勿手写它们。

---

## 3. Packages

**`codex-triage`**（扁平 package）—— 读取/评分侧。
- `raisers/issues.lua`：轮询 `openai/codex` issue，以**小载荷**
  `{source_ref, dedup_key, schema, score}` 触发 `codex_candidate`。
- `departments/score_dedup`：应用评分标准（rubric，R1–R4）+ 聚类 → 标记为 `attemptable`。

**`codex-saga`**（composed package，`persistence_class = "saga"`，依赖 `codex-triage`）
—— 诊断→提议侧；使用 `once(key, fn)` 实现幂等的 saga 步骤。
- `diagnose`（诊断）→ `dossier`（卷宗）→ `gate`（门槛）→ `engage`（互动）→ `open_pr`（开 PR）；`invite_watch` raiser。

两者都遵循 package 仓库契约：`core.lua`（纯共享逻辑）、`departments/<d>/main.lua`
（返回 `M.spec` + 全局 `pipeline(event)`）、`raisers/<r>.lua`（返回一个 source
声明）、`locales/en.lua`、`tests/*_test.lua`。

---

## 4. 配置（`.fkst/env`，双平面，按设备）

```sh
# 目标 —— 让两个“上游”保持区分（不要与 devloop 的
# FKST_DEVLOOP_UPSTREAM_BRANCH 冲突，后者指的是一个汇总（rollup）分支）
FKST_CONTRIB_TARGET=openai/codex            # 外部：读取 + 受门槛限制的提议
FKST_GITHUB_REPO=ChronoAIProject/codex      # 自有 fork：写入（分支/PR）
FKST_FORK_LOCAL_PATH=/abs/path/to/codex     # 用于 worktree 的本地 fork 克隆
FKST_GITHUB_BOT_LOGIN=<device-bot>          # 设备身份（= gh login）
FKST_FORK_SYNC_BRANCH=main                  # 将 openai/codex main 快进（ff）→ fork main

# 门槛策略
FKST_PROPOSE_REQUIRE_INVITE=1               # 没有记录在案的邀请就不发上游 PR
FKST_PROPOSE_DAILY_CAP=3                    # 对新的上游互动设置数量上限
FKST_PROPOSE_DISCLOSE_AI=1

# 引擎/运行时（substrate 脚手架）：BIN、FKST_RUNTIME_ROOT、FKST_DURABLE_ROOT（必填、
# 安全失败（fail-closed）），FKST_RATE_POOL_ROOT、FKST_CODEX_PERMIT_SLOTS、重试参数
BIN=/abs/path/to/fkst-substrate/target/debug/fkst-framework
```

---

## 5. saga 事务流程（departments · raisers · 队列）

在本仓库的 issue 跟踪器上，**每个候选项对应一个 control issue**；状态转移由程序
产生（标签/标记），绝不手工编辑。

```
[raiser] codex-triage/issues       轮询 openai/codex ─► 触发 codex_candidate {source_ref,dedup_key,schema,score}
            ▼
[dept]  score_dedup                评分标准 + 聚类 ─► attemptable        (R1–R4; AUC 0.73)
            ▼
[dept]  diagnose                   在 fork 上开 sdk_git worktree + spawn_codex_sync：
                                   复现 → git bisect → 定位根因 (file:line) ─► diagnosed
            │ 未复现 → needs_info（丢弃）
            ▼
[dept]  dossier                    讲述（来自 worked_on 语料的先例）+ 推送 demo 分支
            ▼
[dept]  gate                       共识 + 受邀前置条件 + 数量上限 + AI 披露 ─► cleared
            ▼
[dept]  engage                     在 openai/codex 上执行 gh issue/comment ─► engaged
            ▼
[raiser] invite_watch              轮询 issue 以获取维护者邀请 ─► invited
            ▼
[dept]  open_pr                    gh pr create fork→上游 + CLA ─► proposed → 跟踪至合并
```

`engage` 之前的一切都是**本地的，且对公众只读**；`gate`、`engage`、`open_pr`
是仅有的对外动作。

---

## 6. 状态与载荷模型

- **实时状态：** 引擎的 durable 存储（redb），位于 `.fkst/durable`（被 gitignore）。
  本仓库跟踪器上的 **control issue** 在 GitHub 上镜像（mirror）saga 状态。
- **载荷纪律：** 事件只携带 `{source_ref, schema, dedup_key, control}`；
  正文/diff/语料通过 `source_ref` 回读。
- **`dedup_key`** ← `data/open_issue_clusters.json`（将重复项折叠为一个代表项）。
- **`score`** ← 评分标准打分（`METHODOLOGY.md` §5），校准后 AUC 0.730。
- **种子语料** 位于 `data/`：`area_rubric.json`、`open_issue_clusters.json`、`worked_on_full.jsonl`。

---

## 7. 引擎读取 / 写入什么

| 目标 | 读取 | 写入 |
|---|---|---|
| 本工具（项目根） | packages · 配置 · 种子数据 | runtime + durable **状态** · saga **control issue** |
| `fkst-substrate` | ——（它就是 BIN） | — |
| `fkst-packages`（仅当复用 trio 时） | trio 源（已 pin） | — |
| **fork** | 代码库（worktree） | **代码修复**：分支、提交、推送 |
| **openai/codex** | issue（候选项） | **受门槛限制**：issue/comment + PR（仅在受邀时） |

---

## 8. 依赖与 pin

- **引擎：** `fkst-substrate`，由 `.fkst-substrate-ref` pin 住，本地构建为 `BIN`。
- **复用的原语（可选）：** 来自 `fkst-packages` 的 `consensus`、`github-proxy`，
  通过 `fkst.workspace.toml` 的 `[[external_sources]]` + `fkst.lock` pin 住。如果我们
  更希望零外部 package 依赖，这些也可以改为在工具内部实现。
- **codex CLI** 位于 `PATH` 上（由 `spawn_codex_sync` 使用）。
- **`gh`** 以设备 bot 身份认证（repo scope），用于读取/写入/提议。

---

## 9. 搭建运行所需的一切（清单）

1. **引擎：** 克隆 `fkst-substrate`，`cargo build`，记下 `BIN` 路径；设置 `.fkst-substrate-ref`。
2. **Fork：** `gh repo fork openai/codex` → `ChronoAIProject/codex`；将其克隆到本地
   （`FKST_FORK_LOCAL_PATH`）；远程 `origin`=fork，`upstream`=openai/codex。（Fork 的
   Issues 保持**禁用** —— saga issue 位于工具上，而非 fork 上。）
3. **工具仓库：** 创建 `fkst-codex-harness`；运行 `fkst-framework init-package-repo`
   生成脚手架；编写 `packages/codex-triage` + `packages/codex-saga`；将种子语料放入
   `data/`；（可选）在 `fkst.workspace.toml` + `fkst.lock` 中 pin 住 trio。Issues
   **启用**（默认）—— 这是 saga 跟踪器。
4. **codex CLI** 已安装并位于 `PATH` 上。
5. **gh auth** 以设备 bot 身份，具备 `repo` scope。
6. **配置：** 复制 `.fkst/env.example` → `.fkst/env`；设置目标、`BIN`、
   `FKST_FORK_LOCAL_PATH`、稳定的 `FKST_DURABLE_ROOT`/`FKST_RUNTIME_ROOT`/`FKST_RATE_POOL_ROOT`、
   门槛策略、设备身份。
7. **运行：** `scripts/run.sh test`（一致性 + 测试），然后 `scripts/run.sh supervise`。

---

## 10. 门槛与安全

- **gate0** 安全/安保 → `security@openai.com`，绝不公开。
- **受邀前置条件** → 没有记录在案的维护者邀请就不发上游 PR。
- **共识** → 在任何外部平面写入之前进行多角度批准。
- 每次上游发帖都要**数量上限 + AI 披露**。
- **破坏性的远程操作**（关闭/强制推送/删除）按 FKST 原则受门槛限制。
- 引擎改动 → 仅 `fkst-substrate`；行为改动 → 本仓库的 packages。

---

## 11. 待定决策

1. **外部平面的门槛模型** —— 仅共识（无人值守）vs 在最初 N 次上游互动中设置人工
   检查点，直到 bot 赢得声誉。
2. **能力授予拆分** —— 为“写入 fork”与“写入 openai/codex”设置不同的计量授予
   （host 侧策略；可能无需引擎改动）。

---

## 12. 与现有 FKST 规格的映射

- **control-plane / host-run separation**（2026-06-23）—— 工具（控制）≠ fork（目标）。
- **godpattern-dissolution**（2026-06-29）—— 聚焦的 packages，而非 devloop 上帝对象。
- **issue-pr-saga-split**（2026-06-20）—— saga 在外部 issue ↔ fork 分支之间重新拆分。
- **unify gh/git egress**（2026-06-16）—— 所有外部/fork 写入都经由计量出口（egress）。

*参见 `repo-architecture.md`（权威的 3 仓库章程 + 锁定决策）、
`codex-contribution-playbook.md`、`METHODOLOGY.md`、`pilot-results.md`。*
