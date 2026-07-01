<div align="center">

[![English](https://img.shields.io/badge/English-1f6feb?style=for-the-badge)](fork-sync-runbook.md)&nbsp;[![简体中文](https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-8b949e?style=for-the-badge)](fork-sync-runbook.zh-CN.md)

</div>

# Fork-sync runbook (codex-fork)

Runbook portion extracted from the Task B fork bootstrap report. The fork
(`ChronoAIProject/codex`, local at `FKST_FORK_LOCAL_PATH`) is a **pristine mirror**
of upstream `openai/codex`. These steps SYNC AND PUSH and are **separately gated** —
they are NOT part of normal harness `test`/`supervise` and keep `FKST_GITHUB_WRITE`
discipline.

Remotes on the fork clone: `origin` = fork (`ChronoAIProject/codex`),
`upstream` = `openai/codex`.

## Demo compare-link format string

Fix-branch PR / compare URL template (used when fix branches exist):

```
https://github.com/openai/codex/compare/main...ChronoAIProject:codex:fix/<issue#>-<slug>
```

Example: `https://github.com/openai/codex/compare/main...ChronoAIProject:codex:fix/30269-nagle-rendezvous-ws`

## Routine mirror sync (run only when gated/approved)

1. Fetch upstream (read-only):
   ```
   git fetch upstream --tags
   ```
2. Fast-forward local `main` (no merge commits — the mirror must stay linear):
   ```
   git checkout main
   git merge --ff-only upstream/main      # abort + report if non-ff divergence
   ```
3. Push the fast-forwarded `main` to the fork (**PUSH STEP — gated**):
   ```
   git push origin main
   ```
   — or, equivalently, sync the fork directly via GitHub without a local push:
   ```
   gh repo sync ChronoAIProject/codex --branch main
   ```
   `gh repo sync` performs the upstream→fork fast-forward server-side; use `--force`
   ONLY if upstream history was rewritten and the mirror policy explicitly permits it
   (normally never).

## Invariants to preserve on every sync

- `main` is **fast-forward-only**. If `git merge --ff-only` fails, STOP and report
  divergence — never force-push or rebase the mirror's `main`.
- **No harness/fkst files** are ever added to the fork. Its directory layout stays
  byte-identical to upstream. Harness/saga tooling lives in THIS repo, not the fork.
- Fix branches (`fix/<issue#>-<slug>`) are created later, off `main`, and pushed to
  `origin` (the fork) for PRs against upstream — they do not pollute `main`.

## Fork Issues should stay DISABLED

The fork's GitHub **Issues should remain disabled**: the saga / work tracker lives on
the **harness** (this repo), not on the fork. Keeping fork Issues off prevents a
parallel, drifting tracker and keeps the fork a clean mirror + PR-source only.
