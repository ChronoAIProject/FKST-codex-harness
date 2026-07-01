<div align="center">

[![English](https://img.shields.io/badge/English-8b949e?style=for-the-badge)](ARCHITECTURE.md)&nbsp;[![简体中文](https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-1f6feb?style=for-the-badge)](ARCHITECTURE.zh-CN.md)

</div>

# fkst-codex-harness — 架构与接线

harness（工具）的结构：每个 package 做什么、哪些内容提交到哪个 repo、issue 记录在
何处，以及运行时这一切是如何接线在一起的。
_截至 2026-07-01。权威设计规范：`fkst-codex-harness-architecture.md`
（合并后的规范）、`learning-model.md`（三环自学习）、
`METHODOLOGY.md`（评分器/校准）。_

---

## 1. 各个 repo（我们编写的三个 + 一个固定的引擎）

| Repo | 平面（Plane） | 在此跟踪/提交 | 不在此处（gitignored / 禁止） |
|---|---|---|---|
| **`ChronoAIProject/codex`**（fork；本地 `codex-fork/`） | 目标 | 上游 codex 代码 + `fix/<issue#>-<slug>` 分支（实际的修复）。`main` = `openai/codex` 的纯净 fast-forward 镜像（mirror）。 | 无 harness 文件；不向 `main` 提交；**Issues 已禁用** |
| **`fkst-codex-harness`**（本 repo） | 控制平面 | `packages/`、`libraries/`、`data/`（种子语料 + 蒸馏后的学习库）、`docs/`、`scripts/`、配置模板 | `.fkst/`（运行时 + 持久状态）、原始 `outcomes*.jsonl`、`target/`、`fkst.env` |
| **`fkst-substrate`** | 引擎 | Rust 引擎；构建 `BIN`（`fkst-framework`） | 任何 codex 特有的内容 |
| **`openai/codex`** | 外部（非我方） | — 只读的 issue 来源；受门槛约束的提议目标 | 除受门槛约束的 issue-comment / PR 外，我们从不写入 |

**FKST 基石：** 控制平面（本 harness）≠ 运行目标（fork）。引擎*监督（supervise）*
harness；fork 只是一个被管理的资源。

---

## 2. 每个 package 做什么（全部位于 `packages/` 下）

### `codex-triage` — 发现 + 评分（flat，`persistence_class="stateless_adapter"`）
- `raisers/issues.lua` — 静态 cron 源（5m）→ `codex_issue_poll_tick`。
- `departments/score_dedup` — 读取 `openai/codex` 的 open issue，通过
  `libraries/rubric`（评分标准；area-tier + type + anatomy + demand，METHODOLOGY §5）
  为每个 issue 评分，应用 security/Tier-D 硬丢弃（hard-drop）与 ATTEMPT 门槛（gate），
  按正确顺序对簇（cluster）去重（**score → bin → ATTEMPT → dedup**），并为归入
  ATTEMPT 分箱（bin）的簇代表 raise `codex_candidate`
  `{source_ref, dedup_key, schema, score}`。
  发现（discovery）源的优先级：注入的 `payload.issues` → 持久的 **issue mirror（镜像）**
  → **fail-closed（安全失败）**（不 raise 任何内容 + 记录日志；绝不在 tick 内做实时拉取）。
  一个 top-N 上限（`FKST_TRIAGE_MAX_CANDIDATES`，默认 5）限定了下游 diagnose 的
  扇出（fan-out）。
- **Issue mirror（带外 reconcile / 对账）。** 完整的分页 open-issue 轮询*不*在
  30s 停顿（stall）tick 内运行 —— 在 `openai/codex` 的规模下（约 8k 个 issue、约 126s）
  会超时并使发现（discovery）陷入饥饿。`scripts/reconcile_issues.py`（一个运维型生产者，
  以 N 天为周期运行）执行可续传的逐页拉取，带 checkpoint/重试/**validate-before-swap
  （换入前校验）**，并将紧凑的 mirror `{source_ref, score-inputs, labels, reactions, updated_at}`
  （绝不含 body）原子地写入 `$FKST_DURABLE_ROOT/codex-issue-mirror/`（gitignored，
  绝不写入 `data/`）。它拥有全部分页/水位（watermark）状态；`codex-triage` 保持为一个
  `stateless_adapter`，只读取 mirror + 新鲜度戳记。（不存在 `stateful_adapter` 类，
  且 mirror 不是 saga（事务流程）—— 所以这是一个脚本，而非 package。）陈旧的 mirror
  会 fail closed（安全失败）。
- 这是**以成功的 linked-PR issue 为依据的 issue 发现**：rubric 派生自 PR-linked 的胜绩
  与 `not_planned` 的败绩之对比，以 *fixed-by-linked-PR* 为键，绝不用
  `state_reason=completed`。

### `codex-saga` — diagnose→propose→learn 事务流程（saga）（composed，`persistence_class="saga"`，`[event_deps]=["codex-triage"]`）
Departments（接线后的链）：
`diagnose` → `implement` → `dossier` → `gate` → `engage` → `invite_watch` → `open_pr` → `track` → `outcome_watch` → 终态 `tracked`。

| Department | 作用 | 平面（Plane） |
|---|---|---|
| `diagnose` | 在 fork worktree 上复现 + `git bisect` + 根因分析 | 本地（fork） |
| `implement` | 检索最相近的 merged-PR 范例（`precedent`+`repo_map`）→ 在 fork worktree 上写入修复 | 本地（fork），dry-run（试运行） |
| `dossier` | 先例故事（precedent story）+ 演示分支；检索互动（engagement）范例 + styleguide | 本地 |
| `gate` | gate0 安全路由排除（route-out） · 邀请前置条件 · 体量上限 · AI 披露 · advocate/consensus | gate（门槛） |
| `engage` | 在 `openai/codex` 候选上发布 dossier（卷宗）issue/comment + 创建 control issue | **外部写入（受门槛约束、dry-run）** |
| `invite_watch` | 轮询 control issue 以等待维护者邀请 | 只读 |
| `open_pr` | 打开 fork→上游 PR + CLA —— **硬性邀请前置条件（重新推导）** | **外部写入（受门槛约束、dry-run）** |
| `track` | 向持久通道追加初始的 §5 outcome（`proposed/pending`） | 本地持久 |
| `outcome_watch` | 从 GitHub 重新推导真实的 PR CI/review/merge 处置结果（只读）→ 追加最终的 §5 outcome | 只读 + 本地持久 |

Raisers：`invite_watch`（15m）、`outcome_watch`（30m）。`engage` 之前的一切对外部而言
都是本地 + 只读的；`gate`/`engage`/`open_pr` 是仅有的对外动作，除非
`FKST_GITHUB_WRITE=1`，否则全部为 dry-run。

### `codex-learn` — 计划性的自我改进（flat）
- `raisers/relearn.lua` — 静态 cron 源（每周，`FKST_RELEARN_INTERVAL`）→ `codex_relearn_tick`。
- `departments/relearn` — 将我们已解决的 outcome 折叠进语料库；重新拟合 rubric
  （**仅当 AUC ≥ 0.70 且 per-bin 单调时才接受**，否则保留先前版本）；重新归纳两份
  styleguide；对范例重新排序；校准 advocate。它**总是**快照
  `data/learning/rubric_history/area_rubric.<ts>.json` 并追加一行 `relearn_log.jsonl`
  —— **即便在被拒绝时也如此** —— 以便 rubric 漂移 + 学习结果得到版本化并可审计。
  它是已提交学习库的**唯一**写入者。

### `libraries/`（纯粹、共享、无运行时副作用）
`rubric`（唯一的评分器实现） · `precedent`（TF-IDF 检索） · `repo_map`（area→crate） ·
`advocate`（包裹一个注入的 consensus 的魔鬼代言人（devil's-advocate）） · `workflow`
（vendored 引擎 saga 库，真实 manifest + `VENDORED.pin`）。

---

## 3. 哪些 issue 记录在哪个 repo（关键区分）

| 类别 | Repo | 方式 |
|---|---|---|
| **我们修复的 issue**（候选） | `openai/codex` | **只读** —— 被发现/评分，从不拥有 |
| **我们的 dossier（卷宗）issue-comment**（`engage`） | `openai/codex` | 受门槛约束 + dry-run，附带 AI 披露 |
| **我们的 PR**（`open_pr`） | `openai/codex`（fork→上游） | 受门槛约束、仅限受邀、dry-run |
| **Saga control issue**（每个候选一个；工作跟踪） | **`fkst-codex-harness` tracker**（`FKST_SAGA_TRACKER_REPO`，默认 `ChronoAIProject/FKST-codex-harness`） | 程序生成的 label + 机器人撰写的标记（marker）= saga 状态 |
| **修复代码 / 分支** | `ChronoAIProject/codex`（fork） | 通过 git worktree 的 `fix/<issue>` |
| **（无）** | fork | Issues **已禁用** —— 仅代码 |

一句话概括：**我们处理的 issue 属于 `openai/codex`；我们自己的工作跟踪 issue 位于
harness tracker 上；fork 只承载代码。** 三个各不相同的位置，绝不混淆。

---

## 4. 运行时如何接线

```
fkst-substrate ──cargo build──► BIN (fkst-framework)
                                  │  supervises project-root = fkst-codex-harness
   RAISERS (cron ticks)                      DEPARTMENTS (do the work)
   issues 5m ─► codex_issue_poll_tick ─► [codex-triage.score_dedup]
        reads openai/codex issues, scores via libraries/rubric
        └─► codex_candidate ─►
   [codex-saga] diagnose ─► implement ─► dossier ─► gate ─► engage
        (fork worktree)   (retrieve    (precedent (advocate/ (POST to
                           PR diffs)    +styleguide) consensus) openai/codex)
   invite_watch 15m ─► … ─► open_pr ─► track ─► outcome_watch ─► tracked
   outcome_watch 30m ───────────────────────────┘
   relearn (weekly) ─► [codex-learn.relearn] re-fit rubric + re-induce styleguides

        READ ───────────► openai/codex issues                      (source_ref)
        manage ─────────► ChronoAIProject/codex fork: branch+fix+push (worktrees)
        GATED propose ──► openai/codex issue-comment + (on invite) PR
        track ──────────► control issues on the harness tracker + durable outcomes
```

队列链（composed 图：10 个 department · 3 个 raiser · 13 个 queue）：
`codex-triage.codex_candidate → codex_diagnosed → codex_implemented → codex_dossier →
codex_cleared → codex_engaged → codex_invited → codex_proposed → (track) → (outcome_watch) → codex_tracked`。

---

## 5. 将一切联系在一起的三条数据通道

1. **Events（事件）** 只携带小型 payload `{source_ref, dedup_key, schema, score, + small control}`。
   Body / diff / 语料通过 `source_ref` 重新获取 —— 绝不内联。
2. **Durable outcomes（持久 outcome）** —— saga 将 §5 outcome 记录（append-only，按
   `dedup_key` 采用 latest-wins「最新者优先」）追加到 `FKST_LEARNING_OUTCOMES_PATH`，否则追加到
   `(FKST_DURABLE_ROOT or ".fkst/durable")/codex-saga/outcomes.jsonl`（gitignored）。
   `track` 写入初始的 `proposed/pending`；`outcome_watch` 写入最终的 `merged|closed`
   + 真实的 `ci`/`review_comment_themes`/`engagement_reaction`。
   **这就是自学习反馈通道**，且 `codex-learn/relearn` 读取的正是该路径。
3. **Committed learning banks（已提交的学习库）** —— `relearn` 将这些 outcome 蒸馏为
   `data/area_rubric.json` + `data/learning/{rubric_history/, relearn_log.jsonl, engagement_styleguide.md, pr_styleguide.md}`，
   供 `codex-triage`（rubric）与 `codex-saga`（styleguide + 范例）在下一周期消费。

### 自我改进闭环（端到端）
```
triage picks        (libraries/rubric over the linked-PR-derived corpus)
  └─► saga engages + implements   (precedent retrieval over corpus_engagement / corpus_pr_style + styleguides)
        └─► outcome_watch re-derives the REAL PR CI / review / merge result   (read-only)
              └─► durable outcomes.jsonl
                    └─► codex-learn/relearn folds them → re-fit rubric + re-induce styleguides + calibrate advocate
                          └─► better picks / comments / fixes next round
```

---

## 6. 状态纪律（何为程序状态 vs 已提交内容）

| 类别 | 位置 | 已提交？ |
|---|---|---|
| 活动的 saga 状态、在途事件、每次尝试的原始 outcome | 引擎持久层（redb） + `.fkst/durable`、`.fkst/runtime` | **否**（gitignored） |
| Saga 状态镜像（mirror，可见） | harness tracker 上的 control issue（label + 机器人标记） | N/A（GitHub） |
| 静态种子语料 | `data/{area_rubric.json (base), open_issue_clusters.json, worked_on_full.jsonl}` | 是 |
| 引导（Bootstrap）语料库 | `data/{corpus_selection,corpus_engagement,corpus_pr_style}.jsonl`、`codex-repo-structure.md` | 是（已规范化，携带 source_ref） |
| 蒸馏后的学习库（持续演进） | `data/area_rubric.json`（当前） + `data/learning/*` | **是** —— 版本化；`relearn` 是唯一写入者 |
| 修复代码 + 分支 | fork | 是（在 fork 上，而非此处） |

FKST 规则得以保留：原始/临时的运行时状态不进入 git；只有经程序蒸馏、可审阅的产物
才被提交（这是依据 `learning-model.md` 所作的、限定于 harness 范围的有意选择）。

---

## 7. 配置（双平面、按设备；复制 `env.example` → `.fkst/env`）

```sh
FKST_CONTRIB_TARGET=openai/codex               # 外部：读取 + 受门槛约束的提议
FKST_GITHUB_REPO=ChronoAIProject/codex         # 自有 fork：写入（分支/PR）
FKST_FORK_LOCAL_PATH=/abs/path/to/codex        # 用于 worktree 的 fork 克隆
FKST_SAGA_TRACKER_REPO=ChronoAIProject/FKST-codex-harness   # control issue 所在位置
FKST_PROPOSE_REQUIRE_INVITE=1 · FKST_PROPOSE_DAILY_CAP=3 · FKST_PROPOSE_DISCLOSE_AI=1
FKST_RELEARN_INTERVAL=168h                     # 自我改进的周期
BIN=/abs/path/to/fkst-substrate/target/debug/fkst-framework
# FKST_GITHUB_WRITE 未设置 = dry-run（默认）；=1 = 真实的对外写入
```

默认以 **dry-run（试运行）** 发布。上线 = 填写 `.fkst/env`，设置
`FKST_GITHUB_WRITE=1`，然后 `scripts/run.sh supervise`。

---

## 8. 构建与测试

`scripts/run.sh check`（repo 守卫 + deps） · `scripts/run.sh test`（self-test +
每个 package 的 conformance + 测试 + composed conformance + G5 覆盖率）。当前：green
（全绿）—— codex-triage 43 · codex-saga 80 · codex-learn 23 个测试，composed
conformance 8/8，`core.saga_conformance_errors` 无报错。`scripts/run.sh` 是一处有文档
记录的多 package 适配（基础脚手架（scaffolder）生成的是单根 runner；见其头部注释）。
```
