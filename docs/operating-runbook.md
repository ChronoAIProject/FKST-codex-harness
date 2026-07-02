# Operating runbook — driving the FKST codex-harness

How to drive the loop with the substrate (engine → `BIN`) + this harness. Companion to
[`fkst-codex-harness-architecture.md`](fkst-codex-harness-architecture.md) (the spec),
[`repo-architecture.md`](repo-architecture.md) (the 3 repos), and
[`fork-sync-runbook.md`](fork-sync-runbook.md) (gated fork writes).

## The two rules that govern everything

- **Two planes.** `openai/codex` (`FKST_CONTRIB_TARGET`) is **read + gated-propose only** — never
  auto-write. The fork `ChronoAIProject/codex` (`FKST_GITHUB_REPO`) is the **only writable code
  surface**. Everything before `engage` is local + read-only to the public.
- **Dry-run by default.** `FKST_GITHUB_WRITE` stays **unset** in `.fkst/env`. No external write
  (gh issue/comment/PR, fork push) happens until it is set **inline on one authorized command**,
  and only after the gates pass. Keep it unset as the resting state.

## One-time setup

1. **Engine (substrate).** Built in the sibling repo: `cd ../FKST-substrate && cargo build -p
   fkst-framework`. Point `BIN` at `target/debug/fkst-framework` in `.fkst/env` (or rely on
   `scripts/run.sh` resolution). Rebuild only when the engine changes.
2. **`.fkst/env`** (per-device, gitignored) holds `BIN`, `FKST_RUNTIME_ROOT`, `FKST_DURABLE_ROOT`,
   the two-plane targets, `FKST_FORK_LOCAL_PATH`, the bot login, and the gate policy
   (`FKST_PROPOSE_REQUIRE_INVITE`, `FKST_PROPOSE_DAILY_CAP`, `FKST_PROPOSE_DISCLOSE_AI`).
3. **Fork checkout** present at `FKST_FORK_LOCAL_PATH` (`../codex-fork`).

## The drive recipe

```bash
cd /Users/chronoai/Desktop/projects/FKST-codex-harness

# 1. Refresh the corpus the loop scores (checkpointed; --resume to continue, --max-pages N to smoke)
#    OPTIONAL when the loop runs long enough: with no usable mirror, codex-triage's in-package
#    bootstrap pulls the same corpus SLOWLY on its own (a few pages per 5m tick, ~2h for ~8k
#    issues; FKST_TRIAGE_BOOTSTRAP=0 disables). Running the script here is just the fast path.
python3 scripts/reconcile_issues.py

# 2. Clear stale runtime scratch so nothing short-circuits from a prior/killed session
scripts/clean_runtime.sh

# 3. Sanity-check
scripts/run.sh check          # repo guards + KB validation + engine deps
# scripts/run.sh test         # + self-test + conformance + per-package tests (slower)

# 4. DRIVE — the FKST event loop (dry-run; Ctrl-C to stop)
scripts/run.sh supervise      # add a package name to scope one composed graph, e.g. `supervise codex-saga`
```

`supervise` is **autonomous** — you do not hand-crank stages. Its cron raisers tick (triage every
300s), score the mirror, raise candidates, and the saga runs each through
`diagnose → implement → dossier → gate → engage → invite_watch → open_pr → track`, invoking codex
per stage. It runs until you stop it; state is durable, so a kill is safe to resume from.

## Watching it (two surfaces, one durable source)

```bash
# Terminal TUI — funnel + per-state scoreboard + outcomes, refreshing in place
FKST_FRAMEWORK_BIN=$PWD/../FKST-substrate/target/debug/fkst-framework \
  python3 scripts/track_run.py           # --once for a single snapshot

# Web dashboard on :3210 (sibling repo)
cd ../FKST-codex-harness-dashboard
FKST_DURABLE_ROOT=$PWD/../FKST-codex-harness/.fkst/durable npx next dev -p 3210

# Raw live delivery state
fkst-framework observe --durable-root .fkst/durable --json
```

Both read the same durable state: `codex-saga/outcomes.jsonl` (terminal outcomes: `needs_info`
drops, gate refusals, `cleared` milestones) merged with `observe` (in-flight queue depth). See
`FKST-codex-harness-dashboard/docs/DATA-RETRIEVAL.md`.

## Where state lives

| Layer | Path | Kind |
|---|---|---|
| **Durable** (kill-safe, resumable) | `.fkst/durable/` — `delivery.redb` + `codex-saga/outcomes.jsonl` + `codex-issue-mirror/` | program state; **never hand-edit** |
| **Runtime scratch** (clearable) | `.fkst/runtime/` — `locks/`, `logs/codex-adoption/`, `worktrees/`, `logs/` | safe to clear with `clean_runtime.sh` |

## Keeping track — annotate an outcome

```bash
# Stop supervise first, then attach a durable finding to a candidate (shown on dashboard + TUI)
python3 scripts/annotate_outcome.py --issue 16205 --reason already_fixed_upstream \
  --note "Already fixed upstream by openai/codex#18499; not a propose candidate."
```

## Going live — the gated write path

Everything is dry-run until you opt in **per command**. When a candidate is genuinely worth
proposing **and you have been invited**, set `FKST_GITHUB_WRITE=1` inline on the specific authorized
step. The gates still must pass in order: **invitation precondition → multi-angle consensus →
volume cap → AI-disclosure**. Security/safety-labelled issues are routed privately and never posted.
Fork branch pushes go through [`fork-sync-runbook.md`](fork-sync-runbook.md). Never write to
`openai/codex` except a gated, invited propose.

## Stopping & resuming

- **Stop:** `Ctrl-C`, or `pkill -f 'fkst-framework supervise'`.
- **Resume:** just run `supervise` again — it picks up durable delivery state.
- **Fresh start:** `scripts/clean_runtime.sh` (stopped first) clears scratch so a re-diagnosis is not
  served from a cached verdict; durable outcomes/mirror are left intact.

## Troubleshooting

- **A candidate finishes diagnosis in ~2s with `not_reproduced` (no codex run).** Stale codex-adoption
  cache from a prior session. Stop supervise → `scripts/clean_runtime.sh` → re-run.
- **codex binary blocked at launch (macOS XProtect / "malware").** Verify the binary is the genuine
  signed release (`codesign -dv "$(command -v codex)"` → Developer ID: OpenAI OpCo). If it is, this is
  an XProtect false positive; do not disable Gatekeeper — resolve the flag before running codex steps.
- **`observe` errors "open existing durable delivery database".** No `delivery.redb` yet — it is
  created on first `supervise`; run the loop once.
- **Runtime-panic bugs (e.g. a launch crash) drop to `needs_info`.** `diagnose` is read-only and
  reproduces by inspection; it cannot reproduce something that only manifests when the CLI is *run*.
  Those need manual reproduction on the fork.
