<div align="center">

[![English](https://img.shields.io/badge/English-8b949e?style=for-the-badge)](METHODOLOGY.md)&nbsp;[![简体中文](https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-1f6feb?style=for-the-badge)](METHODOLOGY.zh-CN.md)

</div>

# 方法论 — Codex Issue 分诊与评分流水线

可复现地记录了我们如何从"8.8k 个 closed + 7.7k 个 open issue"得到一份经过
calibration（校准）、dedup（去重）、可尝试处理的开放 issue 候选短名单。所有步骤都是
只读的 GitHub API 调用（`gh`）加上本地 Python（不使用付费服务，也不用 sklearn/numpy）。

- **已关闭 issue 扫描：** 2026-06-29 · **开放 issue + 试点运行：** 2026-06-30
- **Repo：** `openai/codex` · **Auth：** `gh`（5,000 req/hr）

---

## 0. 流水线概览

```
                 ┌─ closed issues (8,871) ──┐
 DATA PULL ──────┤  open issues   (7,651)   ├── all via gh REST/GraphQL
                 └─ merged PRs    (284)     ┘
        │
        ▼
 IMPORTANCE SIGNAL   "fixed by a linked PR" (614), NOT state_reason=completed
        │
        ▼
 RUBRICS (R1–R4)  ←  derived from fix-rate-by-area + merged-PR profile
 HYPOTHESES (H1–H5) ← what a merged PR looks like
        │
        ▼
 SCORING FUNCTION  score = area_tier + type + anatomy + demand
        │
        ▼
 CALIBRATION   score 614 winners vs 1,457 rejected → AUC + per-bin PR-linked rate
        │
        ▼
 FILTER FUNNEL  hard-drops → bins → ATTEMPT gate → dedup → key-area narrowing
        │
        ▼
 OUTPUT   ranked working candidates (853 in key areas; 54 high-confidence)
```

---

## 1. 数据采集

| 数据集 | 查询 | 字段 | 文件 |
|---|---|---|---|
| 全部已关闭 issue | `GET /repos/openai/codex/issues?state=closed --paginate`，过滤掉 PR（`has("pull_request")`） | number, author_association, state_reason, labels, assignees, comments | `codex_closed_issues.jsonl` |
| 处理过的（PR-linked，有关联 PR） | 先用 `search/issues q="state:closed linked:pr"`，再用 GraphQL `closedByPullRequestsReferences` | + 完整 body、reactions、关闭该 issue 的 PR（number, merged, author） | `worked_on.jsonl`、`worked_on_full.jsonl` |
| 开放 issue | `GET /repos/openai/codex/issues?state=open --paginate`，过滤掉 PR | number, title, body[:600], labels, reactions, comments | `open_issues.jsonl` |
| 被拒绝的（negatives，负样本） | `state_reason==not_planned` → GraphQL | 完整 body、labels、reactions | `not_planned_full.jsonl` |
| 已合并 PR | 对 324 个关闭 issue 的 PR 执行 GraphQL `pullRequest` | additions, deletions, changedFiles, commits, author_association | `merged_pr_stats.json` |

GraphQL 以每请求约 35–40 个别名节点（aliased nodes）的方式批量查询，以便远低于速率限制（rate limit）。

---

## 2. 重要性信号（关键定义）

**重要性 = 该 issue 是被一个*关联的（linked）* PR 关闭的（最好是已合并的），而不是
`state_reason=completed`。** 理由：在 5,861 个"completed"关闭中，**有 5,316 个没有
关联 PR**（未提交代码就关闭了）→ 所以"completed"是噪声。只有 **614 个（6.9%）** 真正
被处理过；**339 个**由已合并 PR 关闭；**545 个**既是 completed 又有关联 PR（linked）。

---

## 3. Rubrics（评分标准，源自过往结果）

- **R1 Area tier（领域等级）** = 各 label 的 fix-rate（修复率）÷ closed（仅统计 ≥40 个 closed 的 label）。`area_rubric.json`。
  - A：`exec regression TUI mcp hooks custom-model documentation config`
  - B/C：`bug sandbox code-review tool-calls CLI windows-os`（其余 3–8%）
  - D（丢弃）：`app model-behavior rate-limits codex-web browser extension auth context safety-check computer-use`
- **R2 Type（类型）：** bug/regression 默认合格；enhancement 除非有大量 demand（需求度）否则排除。
- **R3 Issue 质量记分卡：** 已复现（hard gate，硬性门槛）· 在 `file:line` 定位根因 ·
  version/OS · 复现步骤 · code/log · 简洁（约 200 词）。
- **R4 PR 可合并性：** ≤3 个文件 / ≤200 LOC · 1–2 个 commit · 测试修复前失败/修复后通过 ·
  `just fmt/fix/test` 干净通过 · 可信作者。

---

## 4. 关于什么样的 PR 会被 MERGED（合并）的假设（证据：284 个已合并 PR）

| # | 假设 | 证据 |
|---|---|---|
| H1 | 小而精准（surgical） | 中位数 2 个文件 / 80 LOC；64% ≤3 个文件；77% ≤200 LOC |
| H2 | 高 fix-rate 领域中的 bug，而非新功能 | 修复集中在 Tier-A；0 reaction 的 bug 也会被合并 |
| H3 | PR 依托于一个诊断充分的 issue | 71% 被修复的 issue 都带有复现步骤 + version |
| H4 | 作者已赢得信任 | 283/284 个已合并 PR 来自 COLLABORATOR/CONTRIBUTOR；1 个来自 NONE |
| H5 | 原子化且有测试支撑 | 中位数 2 个 commit；43% 为单 commit |

H1/H4/H5 作用于 PR/作者阶段；H2/H3 + demand 驱动 issue 分诊评分（§5）。

---

## 5. 评分函数（score，精确定义）

对每个 issue 应用，作用于**截断到 600 字符的 body**（使 calibration 数据集与开放 issue
保持一致）。label 决定 area/type；body 决定 anatomy（结构完整度）。

```
HARD DROPS (return SKIP, score 0):
  - label ∈ {safety-check, security}        → SKIP-security (route to security@openai.com)
  - best area tier == D                     → SKIP-tierD

area_tier  : A=40 · B=24 · C=12 · unknown=8        (best tier among the issue's labels)
type       : regression +24
             elif bug +14
             elif enhancement: 12 if reactions≥30 else 6 if reactions≥10 else 1
             else +6
anatomy    : (cap 25)  version|semver +5 · repro/"steps to" +8 · code ``` +4 ·
             OS(macos|windows|linux) +3 · error|panic|stack|exception +5
demand     : min(reactions,40)/40 × 8

score = area_tier + type + anatomy + demand          (max ≈ 97)

BINS:
  ATTEMPT   if score≥58 AND tier∈{A,B} AND (bug|regression) AND repro_ok
  CANDIDATE if score≥45
  LOW       if score≥32
  SKIP      otherwise
  where repro_ok = (anatomy≥8) OR version/semver present
```

注意：`area_tier` 取该 issue 的**最佳（best）** label（一个同属 Windows/app 的 issue，
若它同时是 regression，就可凭 regression 这个 label 合格——这是有意为之，因为 regression
在所有领域都会被修复）。更严格的"主领域（primary-area）"变体是一个可调选项。

---

## 6. Calibration（校准，验证 score 能预测是否被采纳）

- **正样本（Positives）：** 614 个处理过的（PR-linked）issue，完整 body。**负样本
  （Negatives）：** 1,457 个被拒绝的（`not_planned`）issue，完整 body。使用相同的评分函数。
- **AUC = 0.730**（排序统计量；0.5 为随机，1.0 为完美）。
- score 中位数：胜出者（winners）**54** vs 被拒绝者 **41**。
- **各 bin（分箱）的 PR-linked 比率（单调 ⇒ 分箱有预测力）：**
  ATTEMPT **57%** · CANDIDATE 36% · LOW 18% · SKIP 14%。
- 胜出者：73% 落在 ATTEMPT+CANDIDATE。被拒绝者：60% 落在 SKIP+LOW。

每当权重变化时都要重新运行；要求 AUC ≥ 约 0.70 且各 bin 比率单调。

---

## 7. 重复检测（dedup，去重）

纯 Python 实现的 TF-IDF 余弦相似度，配合稀有 token 分块（rare-token blocking）：
- 文本 = title（权重 ×3）+ body[:600]；token 为 `[a-z0-9]{3,}`，并去除停用词（stopwords）。
- `idf = log(N/df)`；权重为 `(1+log(tf))·idf`；向量做 L2 归一化。
- 在满足 `2 ≤ df ≤ 400` 的 token 上建立分块倒排索引；候选邻居 = 与某文档共享其 top-10
  最高 idf token 中任意一个的那些文档。
- 当余弦相似度 **≥ 0.55** 时连边；用并查集（union-find）聚类；代表（representative）= reactions 最多者。
- 结果：96 个簇（clusters），264 个 issue（占开放 issue 的 3%），其中 168 个冗余。**高精确率 /
  保守** —— 真实重复率 ≈17.5%（来自已关闭历史），因此在 ~0.42 阈值上做一次召回（recall）遍历
  （+ embeddings）将能浮现语义级的重复。输出 `open_issue_clusters.json`。

dedup 通过把每个簇的成员收拢到代表（representative）来应用于候选列表。

---

## 8. 过滤漏斗（开放 issue → 候选）

```
7,651 open
  − security/safety           −74      → security@openai.com
  − Tier-D area                −5
  SKIP (score<32)             985
  LOW  (32–45)              1,282
  CANDIDATE (45–58)         4,222
  ATTEMPT (≥58 +A/B +bug|regr +repro)  1,083
  − dedup to representatives          → 1,046  working candidates
  ∩ key areas (Tier-A)               →   853
     · score ≥70 (solid)             →   235
     · score ≥75 (high-confidence)   →    54
```

**关键领域（Key areas，Tier-A）：** `exec regression TUI mcp hooks custom-model documentation config`。
**最佳区间（Sweet spot）：** `regression exec TUI mcp`。

---

## 9. 输出

| 文件 | 内容 |
|---|---|
| `scored_open_issues.json` | 全部 7,651 个开放 issue：score、bin、breakdown（明细）、dup_of |
| `working_candidates.json` | 1,046 个去重后的 ATTEMPT，按 score 排序 |
| `key_area_candidates.json` | Tier-A 领域中 853 个去重后的 ATTEMPT |
| `open_issue_clusters.json` | 96 个重复簇，含完整成员 |
| `area_rubric.json` | 按领域的 fix-rate rubric + tier |
| `merged_pr_stats.json` | 284 个已合并 PR 的规模/commit/作者 |

---

## 10. 可调参数与注意事项

- **阈值（Thresholds）：** score 分箱（58/45/32）、dedup 余弦（0.55）、demand 上限（40）、
  anatomy 权重。任何改动后都要重新校准（§6）。
- **只是预筛选，而非终判：** AUC 0.73 排序效果好，但最终是否动手仍需实时的 R3 hard gate
  （真实复现 + 根因），逐个 issue 进行。
- **600 字符 body 窗口：** 对于较长的 body，anatomy 可能漏检出现在靠后位置的特征。
- **最佳 label 领域：** 可考虑更严格的主领域（primary-area）过滤，以剔除 Tier-D 的共存 label。
- **dedup 召回：** 0.55 偏保守；调低阈值 + 加入 embeddings 可得到更完整的重复关系图。
- **时效性（Freshness）：** issue/PR 状态会漂移；动手前需重新拉取数据。数据截至 2026-06-29/30。

---

## 11. 重新运行顺序

1. 拉取 closed + open + worked-on + not_planned + merged-PR 数据（§1）。
2. 计算 fix-rate rubric → `area_rubric.json`。
3. 对正/负样本评分 → 校准（§6）；若 AUC ≥0.70 且单调则接受。
4. 对开放 issue 聚类（§7）。
5. 对开放 issue 评分 + 分箱（§5），应用漏斗（§8）→ 候选文件（§9）。

*参见 `codex-contribution-playbook.md`（发现 + DOs/DON'Ts，该做/不该做），`pilot-results.md`
（本次运行的结果）。数据截至 2026-06-29 / 2026-06-30。*
