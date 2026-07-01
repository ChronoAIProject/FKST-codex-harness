<div align="center">

[![English](https://img.shields.io/badge/English-8b949e?style=for-the-badge)](dependency-strategy.md)&nbsp;[![简体中文](https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-1f6feb?style=for-the-badge)](dependency-strategy.zh-CN.md)

</div>

# 依赖策略（R2）：内嵌（vendored）`workflow` 库

*由 Task C 于 2026-06-30 经实证确定。权威规范见 §8；补充条款 R2。*

## 决策

`workflow` 库以**内嵌（vendored）**方式放入 `libraries/workflow/`，作为一个最小化、
带真实 manifest 的子集（仅 `saga.lua`）。它**不**通过
`fkst.workspace.toml [[external_sources]]` + `fkst.lock` 来固定版本（pin）。

## 为何选择内嵌（external-source 固定版本方案被否决）

`persistence_class = "saga"` 要求各 department `require("workflow.saga")`
并调用 `.department(...)`，因此必须在 harness 内部解析出一个 `workflow` 库。经批准的
默认方案（补充条款 R2）是从本地 `fkst-packages` 检出（即 `ChronoAIProject/fkst-packages`）
固定版本（pin）出真实平台。

该固定版本方案经过尝试，并在实证中**被引擎否决**：

1. 声明了 `[[external_sources]]`，其中 `git = <local fkst-packages>`、
   `rev = 8704a642f9c61023a2bbb50fade0c24483680eeb`、`libraries = ["workflow", "contract"]`。
2. `fkst-framework deps lock` 解析出了依赖树以及各库的导出哈希（export hashes）并写入了
   `fkst.lock`，**但**随后校验失败，报错：
   ```
   external source `fkst-packages` does not allow library `workflow`
   ```
3. 根因（substrate `manifest.rs::add_external_units`）：external source 只接纳**可发布
   （publishable）**的库（`if !library.publishable { continue }`）；未被接纳的库会落入
   `denied_external_libraries`，消费它时会 fail-close（失败即关闭）。上游 `workflow` 库
   声明的 `[library]` **没有** `publishable = true`，且 `[visibility] public = false`，
   因此它无法跨越 external-source 边界。（`contract` **是** `publishable = true`，可以正常解析。）
4. 在这里 `fkst-packages` 仅供 read/pin/vendor（只读/固定版本/内嵌）使用——无法在源头翻转
   `publishable` 标志——因此固定版本这条路径无法解析出 `workflow`。这正是补充条款所预见的
   “跨仓库 external source 无人能解析”的脆弱性。

## 内嵌了哪些内容（真实，而非伪造）

- `libraries/workflow/saga.lua` —— `fkst-packages@8704a642…:libraries/workflow/saga.lua`
  的**逐字节一致（byte-identical）**副本。它**没有任何 external require**（不依赖
  `contract`），因此是最小的合规子集；完整的上游 `workflow`
  （codex/oracle/sweep/dead_letter/liveness/…）及其传递依赖 `contract` 都刻意**未**内嵌。
- `libraries/workflow/fkst.toml` —— 真实的 `kind = "library"` manifest
  （`[library]` 元信息、`[exports] public = ["workflow.*"]`、`[visibility] public = false`、
  空的 `[lib_deps]`）。
- `libraries/workflow/VENDORED.pin` —— 溯源信息：源仓库、源 SHA、源路径。

两个 package 都声明了 `[lib_deps] libraries = ["workflow"]`。

## 解析与合规性的验证

```
fkst-framework deps --project-root .            # PASS: codex-{triage,saga} -> workflow
fkst-framework conformance ... codex-triage     # PASS 7/7 (flat single-root)
fkst-framework conformance ... codex-saga +     # PASS 8/8, incl.
  codex-triage (composed)                       #   conformance-function core.saga_conformance_errors -> no errors
scripts/run.sh check                            # exit 0
scripts/run.sh test                             # exit 0 (self-test + per-pkg + composed + G5)
```

## 刷新

在固定版本对应的 SHA（或经审阅的更新 SHA）处，从源仓库重新拷贝
`libraries/workflow/saga.lua`，并更新 `libraries/workflow/VENDORED.pin` 中的
`source_sha`。若上游 `workflow` 库将来被发布（`publishable = true`），则 §8 中的
external-source 固定版本方案将变得可行，届时可重新审视此内嵌方案。
