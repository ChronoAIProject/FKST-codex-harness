<div align="center">

[![English](https://img.shields.io/badge/English-8b949e?style=for-the-badge)](codex-contribution-playbook.md)&nbsp;[![简体中文](https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-1f6feb?style=for-the-badge)](codex-contribution-playbook.zh-CN.md)

</div>

# Codex 贡献操作手册（Playbook）

**一份文档：** 调研发现 + 重要性评分标准（rubric）+ issue 剖析 + DOs/DON'Ts（该做/不该做）+
循环（loop）章程。目的是让一个自主的 issue 修复循环产出的成果，能真正让
`openai/codex` 团队愿意*发出邀请并予以合并（invite and merge）*。

- **目标：** 让循环对齐 Codex 切实看重的东西，而非代码量。
- **方法：** 通过 GitHub API（`gh`）扫描 `openai/codex` 上全部已关闭 issue，
  并与其关联/已合并的 PR 交叉比对。**数据截至 2026-06-29。**
- **政策依据：** https://github.com/openai/codex/blob/main/docs/contributing.md
  ——贡献采取**受邀制（invitation-only）**；未受邀的 PR 会被*直接关闭、不予审阅*。

---

## TL;DR（要点速览）

- "对 Codex 重要" = **由关联 PR 修复（614 个，约占已关闭的 7%）**，而非以 completed 关闭
  （5,316 个 "completed" 关闭没有任何代码改动）。
- 修复集中在 **`exec` / `regression` / `TUI` / `mcp` / `hooks`**；Tier-D（D 级）领域
  （`app`、`model-behavior`、`rate-limits`、`safety-check`……）是坟场。
- **默认做 bug** ——凭技术价值获得修复，与需求热度无关。功能特性则是路线图（roadmap）抽奖。
- 制胜的 issue **简洁（约 200 词）+ 版本号 + 复现步骤**；把根因定位到
  `file:line` 是循环的优势所在。
- 局外人也能赢：**81%** 的已修复 issue 由此前毫无背景的人提交；
  **约 57%** 的修复由外部人员编写；**22%** 由提交者自行修复。
- 优化**受邀率（invitation-rate）**与**自修复路径**，绝不是 PR 数量。
- Issue 优先，等待邀请，绝不批量发帖。

---

## 1. 核心发现

| 指标 | 数值 | 含义 |
|---|---|---|
| 已关闭 issue | 8,871 | 语料库整体 |
| 未关闭 issue | 7,700 | 积压待办 |
| 以 `completed` 关闭 | 5,861（66%） | **误导性**信号 |
| 以 `not_planned` 关闭 | 1,457（16%） | 被拒绝 |
| 以 `duplicate` 关闭 | 1,553（17.5%） | 重复冗余 |
| **关联到 PR（"被处理过"）** | **614（6.9%）** | 真正的信号 |
| **由*已合并* PR 关闭（已修复）** | **339** | 代码真正落地 |
| 标记 `completed` 但无关联 PR | 5,316 | 无代码即关闭——**垃圾信号** |
| 指派给团队成员 | 230（2.6%） | 团队明确接手 |

**改变全局的三个发现**

1. **"Completed" 是噪声；"由关联 PR 修复"才是真相。** 只有约 614 个 issue（6.9%）
   真正被处理过；339 个由已合并 PR 修复。定义重要性的是这一小撮，而非那 5,861 个。
2. **团队不公开提交 issue**（OWNER/MEMBER 提交 0 个；COLLABORATOR 提交 38 个）。
   路线图是内部的 → 应从**已合并 PR + CHANGELOG** 推断，而非从 issue 推断。
3. **可量化的信任阶梯：** 老贡献者的完成率为 **73.7%**，而局外人为
   **65.5%**。挣得贡献者身份是有回报的。

---

## 2. 重要性评分标准（rubric）——按领域的修复率

"某领域的 issue 被处理的可能性有多大？"（已修复 ÷ 已关闭，仅统计已关闭 ≥40 的领域）。
机器可读版本：`area_rubric.json`。

### 🟢 TIER A（A 级）——积极主攻
| 领域 | 修复率 | 已修复/已关闭 |
|---|---|---|
| `exec` | 20.2% | 18/89 |
| `regression` | 20.0% | 16/80 |
| `documentation` | 17.7% | 22/124 |
| `hooks` | 15.1% | 8/53 |
| `TUI` | 14.8% | 145/981 |
| `mcp` | 14.7% | 45/307 |
| `custom-model` | 12.4% | 14/113 |
| `config` | 10.4% | 14/134 |

### 🟡 TIER B/C（B/C 级）——仅在有强力、可量化的证据时
`sandbox` 7.6% · `bug` 7.3% · `code-review` 7.3% · `tool-calls` 6.6% ·
`skills` 6.5% · `CLI` 6.0% · `enhancement` 5.6% · `windows-os` 4.7%

### ⚫ TIER D（D 级）——坟场，不要在此耗费精力
`context` 2.8% · `auth` 2.7% · `extension` 2.4% · `connectivity` 1.6% ·
`browser` 1.2% · `codex-web` 1.1% · `app` 0.9% · `model-behavior` 0.5% ·
`rate-limits` 0.5% · `safety-check` 0% · `computer-use` 0%

**从两个维度解读：** 论概率（修复率），`exec`/`regression`/`TUI`/`mcp`/`hooks` 更占优；
论数量（绝对修复数），`bug` 436、`TUI` 145、`enhancement` 131、`CLI` 124、
`windows-os` 55、`mcp` 45、`sandbox` 38 更多。**两者兼得的甜点区：`regression`、`exec`、
`TUI`、`mcp`。**

---

## 3. 已修复 issue 的剖析（614 个"被处理过"的集合）

**谁提交它们**：81% 是纯局外人（NONE），16% 是老贡献者，2% 是团队——
门槛（gate）真实存在，但**并未封死**。

**谁编写修复 PR**：团队 38%，**issue 作者自修复 22%**，其他外部人员 35% →
**约 57% 的修复由外部人员编写。** 自修复路径（提交优质 issue → 受邀 → 自己动手修复）
正是循环端到端的范式模板。

**正文剖析**（占 614 的比例）：

| 要素 | 占比 | 结论 |
|---|---|---|
| 版本号 / semver | **71%** | 近乎必备 |
| 复现步骤 | **71%** | 近乎必备 |
| 操作系统 / 环境 | 44% | 大有帮助 |
| 代码块（```） | 42% | 大有帮助 |
| 日志 / 堆栈跟踪 | 30% | 有帮助 |
| 明确的"预期与实际" | 16% | 锦上添花 |
| 截图 / 图片 | 14% | 锦上添花 |

**篇幅：** 中位数约 **200 词**（1,221 字符），p90 约 3,655。简洁 + 可复现胜过长篇大论。

**Bug 与 enhancement 之争**——决定性的分野：
- **Bug（436 个）：** 反应数（reactions）中位数为 **0**；**64% 零反应却仍被修复** →
  凭技术价值修复，不要求有需求。
- **Enhancement（131 个）：** 需求热度并不能预测是否会被修复（多数被修复的功能反应数 <10）；
  受不可观测的内部路线图把控。**这是一场抽奖——默认做 bug。**

### 由数据推导出的制胜 issue 模板

```
Title: <area>: <specific symptom>          e.g. "TUI: output truncated on scroll"

**Version:** codex 0.xx.x   **OS:** macOS 14 / Windows 11 / Ubuntu 22   (71% + 44%)

**Steps to reproduce:**                      (71%)
1. ...
2. ...

**Expected:** ...
**Actual:** ...  <paste log / stack trace>   (30% include logs)

```<code/config that triggers it>```          (42%)

**Root cause (if known):** <file:line + mechanism>   ← the loop's edge

Keep it ~200 words.
```

### 值得研读的范例（黄金标准）

Bug/regression：[#2558](https://github.com/openai/codex/issues/2558)（TUI 截断）、
[#2860](https://github.com/openai/codex/issues/2860)（Windows 权限刷屏）、
[#29189](https://github.com/openai/codex/issues/29189)（MCP/sandbox）、
[#2137](https://github.com/openai/codex/issues/2137)、
[#4707](https://github.com/openai/codex/issues/4707)。
高需求且胜出的功能特性：[#2890](https://github.com/openai/codex/issues/2890)
（406 个反应）、[#2798](https://github.com/openai/codex/issues/2798)、
[#2129](https://github.com/openai/codex/issues/2129)。
全文见 `_exemplars.json`；全部 614 条正文见 `worked_on_full.jsonl`。

---

## 4. ✅ 该做（DOs）

- 以**"由关联 PR 修复"**衡量重要性，绝不用 `state_reason=completed`。
- 优先瞄准 **Tier A**：`exec`、`regression`、`TUI`、`mcp`、`hooks`。
- **优先处理 regression**（回归缺陷，修复率 20%）：自动 `git bisect` 定位到引入问题的 PR 并加以引用。
- 借助**文档修复这一切入点**（`documentation` 17.7%，低风险）从 NONE 爬升到 CONTRIBUTOR，再去攻坚核心 bug。
- 以**可验证的复现 + 定位到 `file:line` 的根因**开场——难点在诊断，而非写代码。
- **严格去重**，比对整个语料库——17.5% 的关闭都是重复。
- **量化影响**——重复簇规模、反应数、严重程度、是否回归、有无变通方案。
- 以**选项 + 让维护者定夺**的方式呈现方案（"乐意实现你们更偏好的任一方案"）。
- **引用他们的先例**——类似的已合并 PR，或维护者已明确表态的方向。
- 主动点明**系统约束**：sandbox 边界、配置向后兼容、跨平台、不引入新依赖。
- 让**真人充当账号的发声者**（循环起草，真人发布）。
- **从已合并 PR + CHANGELOG 推断路线图**（不存在团队公开提交的 issue）。
- 在提交任何 PR 前**等待明确的邀请**；CLA 评论：`I have read the CLA Document and I hereby sign the CLA`。
- **输出制胜格式**——版本号 + 复现近乎必备；约 200 词。
- **瞄准自修复路径**（占胜局的 22%；也是循环唯一能全程掌控的端到端路线）。
- **默认做 bug**——由技术价值决定；相关时附上代码块 / 日志。

## 5. ⛔ 不该做（DON'Ts）

- **不要提交未受邀的 PR**——会被直接关闭、不予审阅；一旦规模化即等同垃圾信息 → 有封禁风险。
- **不要把 "completed" 当作**团队曾在意的证据（5,316 个没有任何代码改动）。
- **不要在 Tier-D 坟场里提交**（`app`、`model-behavior`、`rate-limits`、`codex-web`、`browser`、`extension`、`auth`、`context`、`safety-check`、`computer-use`）。
- **不要随意提出 enhancement**——头号被拒类别；需要压倒性的需求。
- **不要批量发帖**——限制公开互动（每天 ≤3 次），并始终披露 AI 协助。
- **不要为找路线图去挖掘"团队公开的 issue"**——那种数据根本不存在。
- **不要提交大型/重构 PR、改名/lint 式的无谓改动、新依赖，或范围蔓延。**
- **不要公开发布安全问题**——请发邮件至 security@openai.com。
- **不要断言你无法证明的一致性**——推断 + 让维护者定夺。
- **不要把提交 bug 的门槛设成社区需求**——这对 bug 而言无关紧要。
- **不要长篇大论**——篇幅不是质量信号。

---

## 6. 谁来发出邀请（团队分诊者，按被指派的 issue 统计）

`bolinfest`、`gpeal`、`pakrym-oai`、`etraut-openai`、`fcoury-oai`、
`joeytrasatti-openai`、`easong-openai`、`dylan-hurd-oai`、`aibrahim-oai`、
`jif-oai`、`ccy-oai`、`dedrisian-oai`——约 12 位活跃负责人。这就是你的 issue
必须说服的受众。

---

## 7. 循环章程（循环所加载的内容）

运行契约。每一次上报都必须通过 §7.4 的门槛，并产出 §7.5 的输出。

### 7.1 Codex 的目标（按优先级排序）
- **G1 —— 诊断才是难点。** "找出正确的解决方案才是难点；实现它相对而言简单直接。" →
  循环的产品是分析（复现 + 根因 + 方案）；代码是廉价的最后一步，且仅在受邀时才做。
- **G2 —— 架构一致性优先于吞吐量。** 他们之所以设门槛，是因为贡献者缺乏"架构上下文、
  系统级约束、近期路线图"。 → 在提出方案前先获取这些上下文（§7.2）。
- **G3 —— 优先级 = 社区 + 路线图 + 跨平台。** 从经验看（§2/§3）：
  bug 凭技术价值获得修复；enhancement 是路线图抽奖 → 默认做 bug。
- **G4 —— 受邀制。** 没有留痕的维护者邀请，绝不提交 PR。
- **G5 —— 精挑细选、低噪声。** 低数量、已去重、已披露。垃圾信息与对齐目标背道而驰。

### 7.2 上下文获取（最先运行——弥合信息不对称的鸿沟）
从可观测信号构建一个 `direction-model.json`：架构/crate 布局 + sandbox 边界 + 配置 schema +
`codex --help`；最近约 100 个已合并 PR + CHANGELOG + 里程碑（推断出的路线图）；修复惯例 +
`just` 目标；每个 issue 的优先级信号（反应数、重复簇、标签）。每周刷新。

### 7.3 评分 + 经验调优
基础权重：problem_understood 30（是否已复现？根因是否定位到 file:line？），
approach_alignment 25（是否契合既有模式 + 影响面小 + 0 新依赖 + 0 意外行为变更），
impact_community 20，roadmap_fit 15，cross_platform 10。
`reproduced=false` ⇒ 硬门槛（丢弃 / 需要补充信息）。

**经验性覆盖规则（优先生效）：**
- 评分前先做目标过滤：类型 ∈ {bug, regression}；领域 ∈ Tier A；丢弃 Tier D。
- 加分项：is_regression（最高优先级 + bisect）；正文含版本号 + 复现（近乎必备）；
  根因定位到 file:line（差异化优势）。
- **目标指标：受邀率 + 自修复路径。绝不是 PR 数量。**
- 格式先验：约 200 词，逐字输出 §3 的模板。

一致性不由循环来断言——它在讨论串中达成，并由邀请来确认。

### 7.4 硬门槛（拒绝——没有例外）
- **gate0** 安全/安保问题 ⇒ 切勿发帖；发邮件至 security@openai.com。
- **gate1** 未复现 / 无根因 ⇒ 不得上报。
- **gate2** 人工门槛：未经逐项人工批准，不得向公开仓库发布任何内容。
- **gate3** 没有留痕的维护者邀请，不得提交 PR。
- **gate4** 数量上限：每天新增公开互动 ≤3 次。
- **gate5** 重复防护：不要重复已有评论；仅在能补充有效信息时才追加。
- **gate6** 触及 sandbox/安全/config-schema/公开 API ⇒ 高风险，即便只是评论也需人工签核。
- **gate7** 在每一条公开发帖中披露 AI 协助。

### 7.5 输出契约
**Issue/评论**（经人工批准后）：复现（版本/操作系统/命令/预期与实际）· 根因 file:line ·
影响（反应数/重复/严重程度/回归/变通方案）· 以选项 + 让维护者定夺的方式给出方案 · AI 披露。
**PR**（仅在受邀后）：从 main 切出的聚焦分支 · 原子提交（每个都能编译 + 通过测试）·
修复前失败 / 修复后通过的测试 · 若面向用户则更新文档/`--help` ·
`just fmt && just fix && just test` 全部干净通过 · PR 模板 What/Why/How + 关联 issue ·
模型元数据变更需设置 `input_modalities` + 测试 · CLA 评论。

---

## 8. 数据产物（与本文档放在一起）

| 文件 | 内容 |
|---|---|
| `area_rubric.json` | 机器可读的重要性评分标准（修复率、分级、规则） |
| `worked_on_full.jsonl` | 614 个被处理过的 issue——完整正文 + 关闭它们的 PR |
| `worked_on.jsonl` | 614 个被处理过的 issue——仅元数据 |
| `codex_closed_issues.jsonl` | 全部 8,871 个已关闭 issue——元数据 |
| `_exemplars.json` | 精选的 bug/regression 范例 issue，全文 |

## 9. 推荐的下一步

组建一份带标签的训练/测试集——`worked_on_full.jsonl`（胜局）+ 一批 `not_planned` issue
样本（败局）——让循环的评分器从真实样例中学习胜/败边界，而不是依赖启发式规则。

*数据截至 2026-06-29。*
