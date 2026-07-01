<div align="center">

[![English](https://img.shields.io/badge/English-1f6feb?style=for-the-badge)](README.md)&nbsp;[![简体中文](https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-8b949e?style=for-the-badge)](README.zh-CN.md)

</div>

# fkst-codex-harness

An autonomous, locally-run harness that finds high-value **`openai/codex`** issues,
diagnoses + fixes them on a fork, and proposes them back **by invitation** — aligned to
what the Codex team demonstrably merges, and improving itself over time from its own
outcomes.

It is a **self-hosting FKST Lua package repo**: it owns its packages and runs itself
(`supervise`) against the codex contribution target via the FKST engine (`fkst-substrate`
→ `BIN`). Ships **dry-run by default** — no outward writes until explicitly enabled.

> **New here? Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** — packages, repos,
> where issues are logged, and the full wiring. Agent/dev guide: [`CLAUDE.md`](CLAUDE.md).

## What it does (three loops)

| Package | Role |
|---|---|
| **`codex-triage`** | Issue **discovery + scoring** — scores/dedups the `openai/codex` open-issue set via a rubric derived from *fixed-by-linked-PR* wins (`libraries/rubric`) and raises the **top-N** high-value candidates. Reads a **durable issue mirror** refreshed out-of-band (`scripts/reconcile_issues.py`), never a slow in-tick poll; fails closed without a fresh mirror. |
| **`codex-saga`** | The **saga**: diagnose → implement → dossier → gate → engage → invite-watch → open-pr → track → outcome-watch. Gated, invitation-only, dry-run. |
| **`codex-learn`** | **Scheduled self-improvement** — folds real outcomes back into the rubric + styleguides on a regular cadence (AUC≥0.70 + monotonic accept gate; versioned `rubric_history` + `relearn_log`). |

Shared pure libraries: `rubric` (scorer) · `precedent` (retrieval) · `repo_map` (area→crate)
· `advocate` (devil's-advocate gate) · `workflow` (vendored engine saga lib).

## Repos & where issues live

- **`openai/codex`** — the issues we fix (read-only) + our gated dossier comment + PR.
- **`ChronoAIProject/codex`** (fork) — code + `fix/<issue>` branches only (Issues disabled).
- **this repo** — the **saga control issues** (one per candidate, program-produced labels/markers) + packages/config/data.

See `docs/ARCHITECTURE.md` §3 for the full table.

## Build & test

```sh
# 1. build the engine (sibling checkout)
cargo build -p fkst-framework --manifest-path ../FKST-substrate/Cargo.toml
# 2. point the harness at it + run the gates
export BIN=../FKST-substrate/target/debug/fkst-framework
scripts/run.sh check     # repo guards + dependency resolution
scripts/run.sh test      # self-test + per-package conformance + tests + composed conformance
```

## Run it (go-live)

Ships dry-run. To run for real:
1. `cp env.example .fkst/env` and fill in targets, `BIN`, `FKST_FORK_LOCAL_PATH`, gate policy, device bot identity (see `env.example` / `docs/ARCHITECTURE.md` §7).
2. Authenticate `gh` as the device bot (`repo` scope).
3. **Build the issue mirror:** `python3 scripts/reconcile_issues.py` (resumable full pull →
   `$FKST_DURABLE_ROOT/codex-issue-mirror/`, validate-before-swap) and schedule it every N days
   (cron). `codex-triage` reads this mirror and **fails closed** without a fresh one — it never
   runs the slow full poll inside the tick. Knobs: `FKST_TRIAGE_MAX_CANDIDATES` (top-N, default 5),
   `FKST_TRIAGE_MIRROR_MAX_AGE` (staleness budget, default 2d).
4. Set `FKST_GITHUB_WRITE=1` (otherwise all outward actions stay dry-run).
5. `scripts/run.sh supervise <package>`.

**Safety:** invitation-only PRs, gate0 security route-out, ≤3/day volume cap, AI-disclosure
on every public post — all enforced in `codex-saga/gate`. See `docs/codex-contribution-playbook.md`.

## Docs

[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (structure + wiring) · [`docs/fkst-codex-harness-architecture.md`](docs/fkst-codex-harness-architecture.md)
(spec) · [`docs/learning-model.md`](docs/learning-model.md) (self-learning) · [`docs/METHODOLOGY.md`](docs/METHODOLOGY.md) (scorer +
calibration) · [`docs/codex-contribution-playbook.md`](docs/codex-contribution-playbook.md) (what wins) ·
[`docs/dependency-strategy.md`](docs/dependency-strategy.md) · [`docs/fork-sync-runbook.md`](docs/fork-sync-runbook.md).

## License

Apache-2.0 — see [`LICENSE`](LICENSE).
