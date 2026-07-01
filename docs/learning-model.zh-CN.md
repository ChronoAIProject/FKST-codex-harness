<div align="center">

[![English](https://img.shields.io/badge/English-8b949e?style=for-the-badge)](learning-model.md)&nbsp;[![简体中文](https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-1f6feb?style=for-the-badge)](learning-model.zh-CN.md)

</div>

# 学习模型 — fkst-codex-harness

harness（工具）如何学习*该介入哪些 issue*、*如何评论*以及*如何修复*——并持续改进。_截至 2026-06-30。_

---

## 0. 核心理念（并不存在模型训练）

这里所说的"学习"**并非**梯度训练，而是三种机制协同工作：

1. **Memory（记忆）**——由成功案例构建的示例库（`data/` 中的语料库）。
2. **Retrieval-conditioned generation（检索条件化生成）**——在决策时，department 检索最相近的成功示例，并将它们作为 few-shot 上下文 + 护栏规则喂给 `codex`（`spawn_codex_sync`）。模型会模仿在*相似*案例上奏效的做法。
3. **Feedback re-derivation（反馈再推导）**——`track` 记录*我们*每次尝试的结果；`codex-learn` 包会周期性地根据历史 + 我们的结果重新推导示例库/权重。示例库会朝着真正能为**我们**赢得实际进展的方向漂移。

**语料库本身就是学习。各 department 只从中检索。`codex-learn` 是唯一会改动它们的东西。**无需 ML 基础设施——再推导只是对 JSONL 进行的普通计算（权重拟合、模式归纳、样例排序）。

---

## 1. 三个循环

| 循环 | 学习来源 | 存储形式（`data/`） | 应用者 | 反馈信号 |
|---|---|---|---|---|
| **Selection（选择）**——该介入哪些 issue | 关联 PR 的胜（win）对比 `not_planned` 的负（loss）+ 我们的结果 | `area_rubric.json`（拟合的权重 + 阈值） | 经由 `rubric.lua` 的 `codex-triage/score_dedup` | 对我们所选目标的 reply / invite / merge / ignored |
| **Engagement（介入）**——如何评论 / 参与 | 已合并 issue 的评论**线程**（是什么赢得了邀请） | `corpus_engagement.jsonl` + `engagement_styleguide.md` | `codex-saga/dossier`+`engage`（检索 top-k → few-shot） | 维护者对*我们*评论的反应 |
| **Implementation（实现）**——如何修复（PR） | 收尾 PR 的 **diff** + 仓库规范 + H1–H5 | `corpus_pr_style.jsonl` + `pr_styleguide.md` + `codex-repo-structure.md` | `codex-saga/implement`（检索最相近的 diff） | CI 结果 + 评审意见 + 对*我们* PR 的 merge/reject |

（我们大多是**介入现有**的 issue；只有当某个 dedup 簇没有规范 issue 时，我们才会**创建**一个来归并它——由同一个 selection 打分器决定。）

---

## 2. Memory 制品（`data/`，由 `codex-learn` 重新生成）

| 制品 | 内容 |
|---|---|
| `area_rubric.json` | 拟合的特征权重（area_tier、type、anatomy、demand）+ 分箱阈值 |
| `corpus_selection.jsonl` | 带标签的 issue：胜 win（关联 PR）/ 负 loss（`not_planned`）/ 我方结果 |
| `corpus_engagement.jsonl` | 成功的 issue 线程 + 结果（评论样例库） |
| `engagement_styleguide.md` | 归纳出的规则：先给复现（lead-with-repro）、引用 `file:line`、主动提出实现、询问方向、约 200 词、AI 披露 |
| `corpus_pr_style.jsonl` | 已合并 PR 的 diff + 仓库规范（AGENTS.md/CONTRIBUTING/justfile/lint） |
| `pr_styleguide.md` | 归纳出的规则：规模 ≤3 文件/≤200 LOC、测试先失败后通过（fail-before/pass-after）、原子化、遵循约定 |
| `codex-repo-structure.md` | area→crate 映射（例如 `exec`→`codex-rs/exec`、`mcp`→`codex-mcp`） |
| `open_issue_clusters.json` | dedup 映射 → `dedup_key` |

---

## 3. `codex-learn/relearn` 如何逐一再推导（具体、无 ML）

- **Selection weights（选择权重）**——在 `corpus_selection` + 我们的结果上重新拟合特征权重，以最大化胜/负（win/loss）分离度（AUC）。方法：坐标上升 / 简单逻辑回归拟合。仅当 AUC ≥ 0.70 且每个分箱的胜率保持单调时才接受（来自 `METHODOLOGY.md` 的 gate（门槛））。写入 `area_rubric.json`。
- **Engagement styleguide（介入 styleguide（文风指南））**——对成功线程中的*动作*聚类（开场、"主动提出实现 / 询问方向"这一回合、长度、语气），把反复出现的结构提取为规则，并保留结果最好的评论作为样例库。写入 `engagement_styleguide.md` + 重新排序 `corpus_engagement.jsonl`。
- **PR styleguide（PR 文风指南）**——从已合并的 diff 中提取约定（规模、测试模式、文件布局、提交形态）+ 仓库规范；保留最相近的 diff 样例。写入 `pr_styleguide.md` + 重新排序 `corpus_pr_style.jsonl`。
- **Advocate calibration（advocate 校准）**——`codex-learn/calibrate_advocate` 将 advocate 记录的裁决与实际结果对比 → 调整严格度；把反复出现的*有效*反对意见提升为新的 selection/PR 规则（在下一周期更早地应用）。

---

## 4. 决策时的检索（department 如何"应用"学习）

与我们用于聚类的轻量相似度相同（对 title+body 做 TF-IDF，按 area/type），无需嵌入服务：

```
department (score_dedup | engage | implement):
  1. similarity-rank the relevant corpus vs the target issue (area/type/text)
  2. take top-k exemplars (+ the styleguide rules)
  3. spawn_codex_sync(prompt = task + exemplars + rules)   # imitate what worked
  4. [advocate] gate the output before it is used/posted
```

所以 `engage` 实际上是在说：*"就像这 k 位贡献者在相似 issue 上成功评论的那样来评论这个 issue；并遵守这些规则。"*

---

## 5. 结果与反馈（`codex-saga/track` → `outcomes` 持久化状态）

每次尝试都记录为程序产出的持久化状态（绝不手工编辑）：

```
{ source_ref, picked_score, exemplars_used[],
  engagement_reaction: none|reply|positive|invited|refused,
  ci: pass|fail, review_comment_themes[],
  disposition: merged|closed|ignored | refused_consensus|refused_volume_cap|refused_policy|refused_security,
  advocate_verdict: pass|refuted, advocate_reason,
  consensus_angles: { alignment, blast_radius, devils-advocate }, deliberation_count }
```

`exemplars_used` 支持功劳归因（哪些样例带来了好结果 → 提升它们的排名）。`advocate_verdict` 与 `disposition` 的对比驱动 advocate 校准。

**审议捕获（§7）：** gate 也会在此处记录每一次拒绝，经由 `core.deliberation` —— 逐视角的共识/异议裁决（`consensus_angles`）、判断计数（`deliberation_count`）以及拒绝原因。这次追加是**无条件**的（对 dry-run（试运行）安全），因此"N deliberated · advocate refused M"这一漏斗无需 GitHub 写入即可被检索。`refused_*` 类的 disposition **不属于**已解决集合（`merged|closed|ignored`），所以 `is_resolved_outcome` 会跳过它：拒绝可被检索，但绝不会被（误）计为胜/负——一个被拒绝的选择没有可供评分的真实世界 disposition。

---

## 6. 四阶段循环

```
PHASE 0  bootstrap   codex-learn/relearn (first run): pull threads + diffs,
                     induce styleguides, fit weights → data/
PHASE 1  apply       triage(score) ▸ implement(retrieve diffs) ▸ engage(retrieve comments)
                     — each behind an [advocate] gate
PHASE 2  record      track → outcomes (durable): reaction · CI · review · disposition · advocate
PHASE 3  re-derive   codex-learn (scheduled): append our outcomes to the 3 corpora,
                     re-fit weights, re-induce styleguides, re-rank exemplars, calibrate advocate
        └──────────────────────────── loops back to PHASE 1 ────────────────────────────┘
```

---

## 7. 包映射

| 关注点 | 位于 |
|---|---|
| 检索 + 打分 | `codex-triage/score_dedup` + `libraries/rubric.lua` |
| 检索 + 评论 | `codex-saga/dossier`、`engage` + `libraries/precedent.lua` |
| 检索 + 修复 | `codex-saga/implement` + `libraries/precedent.lua`、`repo_map.lua` |
| 记录结果 | `codex-saga/track` → 持久化 `outcomes` |
| **再推导示例库** | **`codex-learn/relearn`**（定时 raiser） |
| 校准 advocate | `codex-learn/calibrate_advocate` |
| advocate（gate） | `libraries/advocate.lua`（包装 `consensus`） |

---

## 8. Bootstrap 前置要求（阻塞项）

我们只拉取了 issue 的**正文**。在拉取以下内容之前，循环 2 和 3 **没有语料库**：
- 那 614 个 issue 的评论**线程**（尤其是 339 个已合并的）→ `corpus_engagement.jsonl`
- 它们的收尾 PR 的 **diff** + 仓库规范 → `corpus_pr_style.jsonl`
- area→crate 映射 → `codex-repo-structure.md`

`corpus_selection` + `area_rubric.json` 已经存在（`worked_on_full.jsonl`、`not_planned_full.jsonl`，以及已校准的打分器）。

---

## 9. 为何它会改进——以及那道护栏

- **持续改进：** 每一次尝试都会新增带标签的数据（selection）、一条新的评论样例（engagement），以及一条新的 diff+评审记录（PR）。`relearn` 会把它们纳入其中，因此 harness 会朝着*在这个仓库上对我们*奏效的方向优化，而非仅仅依据历史。
- **护栏：** **devil's advocate（唱反调者）** 正是阻止这个循环沦为回音室的东西——一个只从自己自信的选择中学习的循环会强化自身的偏差。advocate 在每一道 gate 处注入异议，而它的裁决本身也会依据结果进行校准。改进由**结果驱动，而非自信驱动**。

*参见 `fkst-codex-harness-architecture.md`（departments / saga（事务流程）），`repo-architecture.md`（仓库架构），`METHODOLOGY.md`（打分器 + 校准），`codex-contribution-playbook.md`（示例库所编码的发现）。*
