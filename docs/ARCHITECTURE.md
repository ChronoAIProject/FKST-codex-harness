# fkst-codex-harness — Architecture & Wiring

How the harness is structured: what each package does, what is committed to which
repo, where issues are logged, and how it is all wired together at runtime.
_As of 2026-07-01. Authoritative design specs: `fkst-codex-harness-architecture.md`
(the consolidated spec), `learning-model.md` (the 3-loop self-learning),
`METHODOLOGY.md` (the scorer/calibration)._

---

## 1. The repos (three we author + one pinned engine)

| Repo | Plane | Tracked / committed here | NOT here (gitignored / forbidden) |
|---|---|---|---|
| **`ChronoAIProject/codex`** (the fork; local `codex-fork/`) | target | Upstream codex code + `fix/<issue#>-<slug>` branches (the actual fixes). `main` = pristine fast-forward mirror of `openai/codex`. | No harness files; no commits to `main`; **Issues disabled** |
| **`fkst-codex-harness`** (this repo) | control plane | `packages/`, `libraries/`, `data/` (seed corpus + distilled learning banks), `docs/`, `scripts/`, config templates | `.fkst/` (runtime + durable state), raw `outcomes*.jsonl`, `target/`, `fkst.env` |
| **`fkst-substrate`** | engine | The Rust engine; builds `BIN` (`fkst-framework`) | Anything codex-specific |
| **`openai/codex`** | foreign (not ours) | — read-only source of issues; gated propose target | We never write except gated issue-comment / PR |

**FKST keystone:** control plane (this harness) ≠ run target (the fork). The engine
*supervises* the harness; the fork is just a managed resource.

---

## 2. What each package does (all under `packages/`)

### `codex-triage` — discovery + scoring  (flat, `persistence_class="stateless_adapter"`)
- `raisers/issues.lua` — static cron source (5m) → `codex_issue_poll_tick`.
- `departments/score_dedup` — reads `openai/codex` open issues, scores each via
  `libraries/rubric` (area-tier + type + anatomy + demand, METHODOLOGY §5), applies
  the security/Tier-D hard-drops and the ATTEMPT gate, dedups clusters in the correct
  order (**score → bin → ATTEMPT → dedup**), and raises `codex_candidate`
  `{source_ref, dedup_key, schema, score}` for cluster representatives that bin ATTEMPT.
- This is **issue discovery grounded in successful linked-PR issues**: the rubric is
  derived from PR-linked wins vs `not_planned` losses, keyed on *fixed-by-linked-PR*,
  never `state_reason=completed`.

### `codex-saga` — the diagnose→propose→learn saga  (composed, `persistence_class="saga"`, `[event_deps]=["codex-triage"]`)
Departments (the wired chain):
`diagnose` → `implement` → `dossier` → `gate` → `engage` → `invite_watch` → `open_pr` → `track` → `outcome_watch` → terminal `tracked`.

| Department | Does | Plane |
|---|---|---|
| `diagnose` | reproduce + `git bisect` + root-cause on a fork worktree | local (fork) |
| `implement` | retrieve nearest merged-PR exemplars (`precedent`+`repo_map`) → write the fix on the fork worktree | local (fork), dry-run |
| `dossier` | precedent story + demo branch; retrieves engagement exemplars + styleguide | local |
| `gate` | gate0 security route-out · invite precondition · volume cap · AI-disclosure · advocate/consensus | gate |
| `engage` | post the dossier issue/comment on the `openai/codex` candidate + create the control issue | **foreign write (gated, dry-run)** |
| `invite_watch` | poll the control issue for a maintainer invite | read-only |
| `open_pr` | open fork→upstream PR + CLA — **hard invite precondition (re-derived)** | **foreign write (gated, dry-run)** |
| `track` | append the initial §5 outcome (`proposed/pending`) to the durable channel | local durable |
| `outcome_watch` | re-derive the real PR CI/review/merge disposition from GitHub (read-only) → append the final §5 outcome | read-only + local durable |

Raisers: `invite_watch` (15m), `outcome_watch` (30m). Everything before `engage` is
local + read-only to the public; `gate`/`engage`/`open_pr` are the only outward actions,
all dry-run unless `FKST_GITHUB_WRITE=1`.

### `codex-learn` — scheduled self-improvement  (flat)
- `raisers/relearn.lua` — static cron source (weekly, `FKST_RELEARN_INTERVAL`) → `codex_relearn_tick`.
- `departments/relearn` — folds our resolved outcomes into the corpora; re-fits the
  rubric (**accept only if AUC ≥ 0.70 AND per-bin monotonic**, else keep the prior);
  re-induces both styleguides; re-ranks exemplars; calibrates the advocate. It **always**
  snapshots `data/learning/rubric_history/area_rubric.<ts>.json` and appends a
  `relearn_log.jsonl` row — **including on rejection** — so rubric drift + learning
  results are versioned and auditable. It is the **only** writer of the committed banks.

### `libraries/` (pure, shared, no runtime effects)
`rubric` (the single scorer impl) · `precedent` (TF-IDF retrieval) · `repo_map`
(area→crate) · `advocate` (devil's-advocate wrapping an injected consensus) · `workflow`
(vendored engine saga lib, real manifest + `VENDORED.pin`).

---

## 3. Which issues are logged at which repo (the key distinction)

| Kind | Repo | How |
|---|---|---|
| **Issues we fix** (candidates) | `openai/codex` | **read-only** — discovered/scored, never owned |
| **Our dossier issue-comment** (`engage`) | `openai/codex` | gated + dry-run, with AI-disclosure |
| **Our PR** (`open_pr`) | `openai/codex` (fork→upstream) | gated, invite-only, dry-run |
| **Saga control issues** (one per candidate; the work-tracking) | **`fkst-codex-harness` tracker** (`FKST_SAGA_TRACKER_REPO`, default `ChronoAIProject/FKST-codex-harness`) | program-produced labels + bot-authored markers = the saga state |
| **Fix code / branches** | `ChronoAIProject/codex` (fork) | `fix/<issue>` via git worktrees |
| **(none)** | the fork | Issues **disabled** — code only |

In one line: **the issues we work on are `openai/codex`'s; our own work-tracking
issues live on the harness tracker; the fork holds only code.** Three distinct places,
never mixed.

---

## 4. How it is wired at runtime

```
fkst-substrate ──cargo build──► BIN (fkst-framework)
                                  │  supervises project-root = fkst-codex-harness
   RAISERS (cron ticks)                      DEPARTMENTS (do the work)
   issues 5m ─► codex_issue_poll_tick ─► [codex-triage.score_dedup]
        reads openai/codex issues, scores via libraries/rubric
        └─► codex_candidate ─►
   [codex-saga] diagnose ─► implement ─► dossier ─► gate ─► engage
        (fork worktree)   (retrieve    (precedent (advocate/ (POST to
                           PR diffs)    +styleguide) consensus) openai/codex)
   invite_watch 15m ─► … ─► open_pr ─► track ─► outcome_watch ─► tracked
   outcome_watch 30m ───────────────────────────┘
   relearn (weekly) ─► [codex-learn.relearn] re-fit rubric + re-induce styleguides

        READ ───────────► openai/codex issues                      (source_ref)
        manage ─────────► ChronoAIProject/codex fork: branch+fix+push (worktrees)
        GATED propose ──► openai/codex issue-comment + (on invite) PR
        track ──────────► control issues on the harness tracker + durable outcomes
```

Queue chain (composed graph: 10 departments · 3 raisers · 13 queues):
`codex-triage.codex_candidate → codex_diagnosed → codex_implemented → codex_dossier →
codex_cleared → codex_engaged → codex_invited → codex_proposed → (track) → (outcome_watch) → codex_tracked`.

---

## 5. The three data channels that tie it together

1. **Events** carry only small payloads `{source_ref, dedup_key, schema, score, + small control}`.
   Bodies / diffs / corpus are re-fetched via `source_ref` — never inlined.
2. **Durable outcomes** — the saga appends §5 outcome records (append-only, latest-wins by
   `dedup_key`) to `FKST_LEARNING_OUTCOMES_PATH` else `(FKST_DURABLE_ROOT or ".fkst/durable")/codex-saga/outcomes.jsonl`
   (gitignored). `track` writes the initial `proposed/pending`; `outcome_watch` writes the
   final `merged|closed` + real `ci`/`review_comment_themes`/`engagement_reaction`.
   **This is the self-learning feedback channel**, and `codex-learn/relearn` reads that exact path.
3. **Committed learning banks** — `relearn` distills those outcomes into `data/area_rubric.json`
   + `data/learning/{rubric_history/, relearn_log.jsonl, engagement_styleguide.md, pr_styleguide.md}`,
   which `codex-triage` (rubric) and `codex-saga` (styleguides + exemplars) consume next cycle.

### The self-improvement loop (end to end)
```
triage picks        (libraries/rubric over the linked-PR-derived corpus)
  └─► saga engages + implements   (precedent retrieval over corpus_engagement / corpus_pr_style + styleguides)
        └─► outcome_watch re-derives the REAL PR CI / review / merge result   (read-only)
              └─► durable outcomes.jsonl
                    └─► codex-learn/relearn folds them → re-fit rubric + re-induce styleguides + calibrate advocate
                          └─► better picks / comments / fixes next round
```

---

## 6. State discipline (what is program-state vs committed)

| Category | Location | Committed? |
|---|---|---|
| Live saga state, in-flight events, raw per-attempt outcomes | engine durable (redb) + `.fkst/durable`, `.fkst/runtime` | **No** (gitignored) |
| Saga state mirror (visible) | control issues on the harness tracker (labels + bot markers) | N/A (GitHub) |
| Static seed corpus | `data/{area_rubric.json (base), open_issue_clusters.json, worked_on_full.jsonl}` | Yes |
| Bootstrap corpora | `data/{corpus_selection,corpus_engagement,corpus_pr_style}.jsonl`, `codex-repo-structure.md` | Yes (normalized, source_ref-bearing) |
| Distilled learning banks (evolving) | `data/area_rubric.json` (current) + `data/learning/*` | **Yes** — versioned; `relearn` is the sole writer |
| Fix code + branches | the fork | Yes (on the fork, not here) |

FKST rule preserved: raw/ephemeral runtime state stays out of git; only program-distilled,
reviewable artifacts are committed (a deliberate, harness-scoped choice per `learning-model.md`).

---

## 7. Config (two-plane, per-device; copy `env.example` → `.fkst/env`)

```sh
FKST_CONTRIB_TARGET=openai/codex               # foreign: read + gated propose
FKST_GITHUB_REPO=ChronoAIProject/codex         # owned fork: write (branches/PRs)
FKST_FORK_LOCAL_PATH=/abs/path/to/codex        # fork clone for worktrees
FKST_SAGA_TRACKER_REPO=ChronoAIProject/FKST-codex-harness   # where control issues live
FKST_PROPOSE_REQUIRE_INVITE=1 · FKST_PROPOSE_DAILY_CAP=3 · FKST_PROPOSE_DISCLOSE_AI=1
FKST_RELEARN_INTERVAL=168h                     # self-improvement cadence
BIN=/abs/path/to/fkst-substrate/target/debug/fkst-framework
# FKST_GITHUB_WRITE unset = dry-run (default) ; =1 = real outward writes
```

Ships **dry-run**. Going live = fill `.fkst/env`, set `FKST_GITHUB_WRITE=1`, then
`scripts/run.sh supervise`.

---

## 8. Build & test

`scripts/run.sh check` (repo guards + deps) · `scripts/run.sh test` (self-test +
per-package conformance + tests + composed conformance + G5 coverage). Current: green —
codex-triage 43 · codex-saga 80 · codex-learn 23 tests, composed conformance 8/8,
`core.saga_conformance_errors` clean. `scripts/run.sh` is a documented multi-package
adaptation (the base scaffolder emits a single-root runner; see its header).
```
