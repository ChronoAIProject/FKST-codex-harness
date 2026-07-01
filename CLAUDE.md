# CLAUDE.md — FKST-codex-harness

## What this is

A self-hosting FKST Lua **package repo**: it owns its packages in top-level
`packages/` and runs itself (`supervise`) against the `openai/codex` contribution
target. An autonomous, locally-run harness that finds high-value `openai/codex`
issues, diagnoses + fixes them on a **fork** (`ChronoAIProject/codex`), and proposes
them back **by invitation only**. The engine lives in a sibling repo
(`FKST-substrate` → `BIN`); this repo holds only the Lua behaviour layer, config,
seed data, and saga state. Authoritative spec: `docs/fkst-codex-harness-architecture.md`.

Three repos (see `docs/repo-architecture.md`): **fork** (code only) ·
**this harness** (packages + config + data + saga state) · **FKST-substrate**
(engine → BIN). NEVER touch `codex-fork`; fork sync is gated (see
`docs/fork-sync-runbook.md`).

## Layout

```
packages/
  codex-triage/   flat,     kind="package",          persistence_class="stateless_adapter"
                  raisers/issues.lua (cron tick) -> departments/score_dedup -> raise codex_candidate
  codex-saga/     composed, kind="package.composed", persistence_class="saga"
                  [event_deps] codex-triage; [conformance] function="core.saga_conformance_errors"
                  departments/{diagnose,dossier,gate,engage,open_pr,invite_watch} (conformant STUBS, TODO Task E)
                  saga chain: diagnose->dossier->gate->engage->open_pr; invite_watch gates open_pr
libraries/workflow/   VENDORED workflow.saga library (saga.lua + manifest). See
                      docs/dependency-strategy.md + libraries/workflow/VENDORED.pin.
data/                 seed corpus (read via source_ref, NOT inlined into payloads):
                      area_rubric.json, open_issue_clusters.json, worked_on_full.jsonl
scripts/run.sh        multi-package runner (R1 EXCEPTION to spec §2 — see its header)
scripts/check_repo.py .github/workflows/ci.yml env.example .fkst-substrate-ref .gitignore README.md
                      = as emitted by `fkst-framework init-package-repo` (do NOT hand-edit)
fkst.workspace.toml   workspace unit catalog
.fkst/                gitignored: env (per-device), runtime/ + durable/ (engine scratch + state)
docs/                 spec + methodology + pilot + playbook + runbooks
```

Both packages follow the package-repo contract: `core.lua` (pure shared logic),
`departments/<d>/main.lua` returning `M.spec` + a `workflow.saga.department` pipeline,
`raisers/<r>.lua` returning a static cron/file_watch source, `locales/en.lua`,
`tests/*_test.lua`. The current departments are **conformant STUBS** marked
`TODO(Task D/E)` — D/E flesh in the real diagnose→dossier→gate→engage→open_pr logic.

## Build / test / supervise

- **Engine BIN:** built in the sibling `FKST-substrate`
  (`cargo build -p fkst-framework` → `target/debug/fkst-framework`). Set
  `BIN=<abs path>` in `.fkst/env`, or rely on `scripts/run.sh` resolution:
  `$BIN > .fkst/env BIN= > fkst.env BIN= > PATH > ../FKST-substrate target/debug`.
- **`scripts/run.sh check`** — `check_repo.py` repo guards + `fkst-framework deps`
  (workspace dependency validation).
- **`scripts/run.sh test`** — `check` + `--self-test` + per-package conformance
  (composed packages skip single-root conformance) + per-package `test --report-json`
  + composed conformance over `[event_deps]` graphs + G5 report-json coverage. Uses
  fresh hermetic runtime/durable roots and unsets `FKST_GITHUB_WRITE`.
- **CI** (`.github/workflows/ci.yml`, as emitted) builds the substrate at
  `.fkst-substrate-ref` and runs the scaffold; for the multi-package layout, inject
  `BIN` and run `scripts/run.sh test`.
- **supervise** (later): the real event loop needs a stable `FKST_DURABLE_ROOT`
  (redb; not the clearable runtime scratch) plus targets/config from `.fkst/env`.

## Two-plane discipline (spec §4, §6, §10)

- **Two distinct targets:** `FKST_CONTRIB_TARGET=openai/codex` (foreign: **read +
  gated propose**, never auto-write) vs `FKST_GITHUB_REPO=ChronoAIProject/codex`
  (owned **fork**: the only writable code surface). Everything before `engage` is
  local + read-only to the public; `gate`/`engage`/`open_pr` are the only outward
  actions.
- **Dry-run by default:** any external write (gh issue/comment/PR, fork push) happens
  only under `FKST_GITHUB_WRITE=1`; otherwise log the intent and return. Keep it
  UNSET. Gates: invitation precondition, consensus, volume cap, AI disclosure;
  destructive remote ops gated.
- **State / payload discipline:** live state is engine durable (redb) under
  `.fkst/durable` (gitignored) + the GitHub control issue on THIS repo's tracker;
  never committed, never hand-edited (program-state is program-only). Reliable
  payloads carry only `{source_ref, schema, dedup_key, + small control}` — NEVER issue
  bodies / diffs / corpus; the consumer re-fetches via `source_ref`. `dedup_key` ←
  `data/open_issue_clusters.json`; `score` ← rubric (`docs/METHODOLOGY.md`).
- Engine changes go to `FKST-substrate` only; behaviour changes go here.

## Docs

`docs/fkst-codex-harness-architecture.md` (spec) · `docs/repo-architecture.md`
(3-repo charter) · `docs/codex-contribution-playbook.md` · `docs/METHODOLOGY.md`
(scoring) · `docs/pilot-results.md` · `docs/dependency-strategy.md` (R2 vendoring) ·
`docs/fork-sync-runbook.md` (gated fork mirror sync).
