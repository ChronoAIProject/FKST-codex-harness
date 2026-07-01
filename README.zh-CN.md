<div align="center">

[![English](https://img.shields.io/badge/English-8b949e?style=for-the-badge)](README.md)&nbsp;[![简体中文](https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-1f6feb?style=for-the-badge)](README.zh-CN.md)

</div>

# fkst-codex-harness

一个自主运行、在本地执行的 harness（工具），用于发现 **`openai/codex`** 中高价值的 issue，
在 fork 上诊断并修复它们，然后**仅在受邀时**将修复提交回上游——对齐 Codex 团队实际会合并的内容，
并根据自身的产出结果持续自我改进。

它是一个**自托管的 FKST Lua 包仓库（package repo）**：它拥有自己的 packages，并通过 FKST 引擎
（`fkst-substrate` → `BIN`）针对 codex 贡献目标运行自身（`supervise`）。**默认以 dry-run（试运行）
方式发布**——在显式启用之前不会有任何对外写入。

> **初次接触？请阅读 [`docs/ARCHITECTURE.zh-CN.md`](docs/ARCHITECTURE.zh-CN.md)** —— 包含 packages、仓库、
> issue 记录位置以及完整接线（wiring）。Agent/开发者指南：[`CLAUDE.md`](CLAUDE.md)。

## 它做什么（三个循环）

| Package | 职责 |
|---|---|
| **`codex-triage`** | **Issue 发现 + 评分** —— 通过源自「由关联 PR 修复（*fixed-by-linked-PR*）」成功案例的评分标准（rubric，见 `libraries/rubric`），对 `openai/codex` 的开放 issue 集合进行评分/去重，并提出**前 N 个（top-N）**高价值候选。它读取一个**持久化的 issue 镜像（mirror）**，该镜像由带外流程（`scripts/reconcile_issues.py`）异步刷新，而非在每次 tick 内做缓慢的实时轮询；若无新鲜镜像则**安全失败（fail closed）**。 |
| **`codex-saga`** | **saga（事务流程）**：diagnose → implement → dossier → gate → engage → invite-watch → open-pr → track → outcome-watch。全程受控、仅限受邀、dry-run。 |
| **`codex-learn`** | **定时自我改进** —— 按固定节奏将真实产出结果折叠回 rubric 与文风指南（styleguides）（AUC≥0.70 + 单调性接受门槛；带版本的 `rubric_history` + `relearn_log`）。 |

共享的纯函数库：`rubric`（评分器）· `precedent`（检索）· `repo_map`（area→crate 映射）
· `advocate`（唱反调门槛）· `workflow`（内置的引擎 saga 库）。

## 仓库与 issue 的存放位置

- **`openai/codex`** —— 我们修复的 issue（只读）+ 我们受控的 dossier 评论与 PR。
- **`ChronoAIProject/codex`**（fork）—— 仅存放代码与 `fix/<issue>` 分支（Issues 已禁用）。
- **本仓库** —— **saga 控制 issue**（每个候选一个，带程序生成的标签/标记）+ packages/配置/数据。

完整表格见 `docs/ARCHITECTURE.zh-CN.md` §3。

## 构建与测试

```sh
# 1. 构建引擎（同级目录检出）
cargo build -p fkst-framework --manifest-path ../FKST-substrate/Cargo.toml
# 2. 让 harness 指向它 + 运行各项校验
export BIN=../FKST-substrate/target/debug/fkst-framework
scripts/run.sh check     # 仓库守卫 + 依赖解析
scripts/run.sh test      # self-test + 各 package 一致性(conformance) + 测试 + 组合一致性
```

## 运行它（上线 / go-live）

默认 dry-run。要真正运行：
1. `cp env.example .fkst/env`，填写目标、`BIN`、`FKST_FORK_LOCAL_PATH`、门槛策略、设备 bot 身份（见 `env.example` / `docs/ARCHITECTURE.zh-CN.md` §7）。
2. 以设备 bot 身份认证 `gh`（`repo` 权限范围）。
3. **构建 issue 镜像：** `python3 scripts/reconcile_issues.py`（可断点续传的全量拉取 →
   `$FKST_DURABLE_ROOT/codex-issue-mirror/`，先校验后原子替换），并安排每 N 天（cron）刷新一次。
   `codex-triage` 读取此镜像，若无新鲜镜像则**安全失败**——它绝不会在 tick 内做缓慢的全量轮询。
   可调参数：`FKST_TRIAGE_MAX_CANDIDATES`（top-N，默认 5）、`FKST_TRIAGE_MIRROR_MAX_AGE`
   （过期预算，默认 2 天）。
4. 设置 `FKST_GITHUB_WRITE=1`（否则所有对外动作都保持 dry-run）。
5. `scripts/run.sh supervise <package>`。

**安全保障：** 仅限受邀的 PR、gate0 安全问题私密转发、每天 ≤3 次的数量上限、每条公开发布都带
AI 披露 —— 全部在 `codex-saga/gate` 中强制执行。见 `docs/codex-contribution-playbook.zh-CN.md`。

## 文档

[`docs/ARCHITECTURE.zh-CN.md`](docs/ARCHITECTURE.zh-CN.md)（结构 + 接线）· [`docs/fkst-codex-harness-architecture.zh-CN.md`](docs/fkst-codex-harness-architecture.zh-CN.md)（规格）
· [`docs/learning-model.zh-CN.md`](docs/learning-model.zh-CN.md)（自我学习）· [`docs/METHODOLOGY.zh-CN.md`](docs/METHODOLOGY.zh-CN.md)（评分器 + 校准）
· [`docs/codex-contribution-playbook.zh-CN.md`](docs/codex-contribution-playbook.zh-CN.md)（什么能被合并）· [`docs/dependency-strategy.zh-CN.md`](docs/dependency-strategy.zh-CN.md)
· [`docs/fork-sync-runbook.zh-CN.md`](docs/fork-sync-runbook.zh-CN.md)。

> 注：以上文档均提供中英双语——点击各页顶部的语言按钮（pill）即可切换。`CLAUDE.md` 与 `LICENSE` 仅提供英文版。

## 许可证

Apache-2.0 —— 见 [`LICENSE`](LICENSE)。
