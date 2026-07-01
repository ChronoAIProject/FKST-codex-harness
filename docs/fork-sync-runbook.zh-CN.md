<div align="center">

[![English](https://img.shields.io/badge/English-8b949e?style=for-the-badge)](fork-sync-runbook.md)&nbsp;[![简体中文](https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-1f6feb?style=for-the-badge)](fork-sync-runbook.zh-CN.md)

</div>

# Fork 同步操作手册（fork-sync runbook，codex-fork）

本操作手册（runbook）部分摘自 Task B 的 fork 引导报告。该 fork
（`ChronoAIProject/codex`，本地位于 `FKST_FORK_LOCAL_PATH`）是上游 `openai/codex` 的
**纯净镜像（pristine mirror）**。这些步骤会**同步并推送（SYNC AND PUSH）**，且是**单独
受控（gated）**的——它们**不**属于常规 harness 的 `test`/`supervise` 流程，并遵守
`FKST_GITHUB_WRITE` 纪律。

该 fork 克隆上的 remote：`origin` = fork（`ChronoAIProject/codex`），
`upstream` = `openai/codex`。

## 演示用 compare 链接格式字符串

修复分支（fix-branch）的 PR / compare URL 模板（当存在修复分支时使用）：

```
https://github.com/openai/codex/compare/main...ChronoAIProject:codex:fix/<issue#>-<slug>
```

示例：`https://github.com/openai/codex/compare/main...ChronoAIProject:codex:fix/30269-nagle-rendezvous-ws`

## 常规镜像同步（仅在受控/已批准时执行）

1. 拉取上游（只读）：
   ```
   git fetch upstream --tags
   ```
2. 快进（fast-forward）本地 `main`（不产生合并提交——镜像必须保持线性）：
   ```
   git checkout main
   git merge --ff-only upstream/main      # abort + report if non-ff divergence
   ```
3. 将已快进的 `main` 推送到 fork（**推送步骤——受控**）：
   ```
   git push origin main
   ```
   ——或者，等效地，不经本地推送而直接通过 GitHub 同步 fork：
   ```
   gh repo sync ChronoAIProject/codex --branch main
   ```
   `gh repo sync` 会在服务端执行 upstream→fork 的快进；**仅当**上游历史被重写且镜像策略
   明确允许时才使用 `--force`（通常永不使用）。

## 每次同步都须保持的不变量

- `main` **仅允许快进（fast-forward-only）**。若 `git merge --ff-only` 失败，则**停止**
  并报告分叉——绝不对镜像的 `main` 进行强制推送或 rebase。
- **绝不**向 fork 添加任何 harness/fkst 文件。其目录结构与上游保持**逐字节一致
  （byte-identical）**。harness/saga 相关工具位于**本**仓库，而非 fork。
- 修复分支（`fix/<issue#>-<slug>`）稍后从 `main` 派生创建，并推送到 `origin`（即 fork），
  用于向上游提交 PR——它们不会污染 `main`。

## fork 的 Issues 应保持禁用

该 fork 的 GitHub **Issues 应保持禁用**：saga / 工作跟踪器位于 **harness**（本仓库），
而非 fork 上。关闭 fork 的 Issues 可避免出现一个平行、逐渐漂移的跟踪器，并使 fork
保持为纯净镜像 + 仅作 PR 来源。
