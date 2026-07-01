# Three-Repo Architecture — Codex Contribution System

> ⚠️ **SUPERSEDED (reference only).** The PRODUCT/HOST split described below was
> a *consolidated away* by the locked decision in
> [`fkst-codex-harness-architecture.md`](./fkst-codex-harness-architecture.md):
> **packages live in this harness repo; there is no PRODUCT/HOST split.** This
> file is retained for historical context on the importance signal + corpus
> only. For the realized layout see the authoritative spec and `../CLAUDE.md`.

What we're building, how the repos are structured, and what each owns.
_As of 2026-06-30._

---

## 1. What we want to achieve

An autonomous, **locally-run** system that finds high-value `openai/codex` bugs,
diagnoses and fixes them on a fork, and proposes them back **by invitation** —
aligned to what the Codex team demonstrably merges (regressions/bugs in core
areas; small, well-diagnosed fixes).

Three repos we author + one pinned dependency, split along FKST's **mechanically
enforced** PRODUCT / HOST-RUN / OPERATOR planes:

| | Repo | Plane | One-line responsibility |
|---|---|---|---|
| 1 | **`ChronoAIProject/codex`** (fork) | target | hold the fixes on isolated branches; nothing else |
| 2 | **`fkst-codex-harness`** | **HOST** | compose the platform on the codex target; hold codex-specifics + saga state |
| 3 | **`fkst-substrate`** | engine | run the loop locally with metered capabilities |
| + | **`fkst-packages`** (pinned) | **PRODUCT** | the reusable foreign-contribution behavior + the trio |

The key discipline (FKST keystone rule): **generic, reusable behavior lives in the
PRODUCT plane (`fkst-packages`); the harness is a HOST repo that *composes* it —
it does not vendor it or reimplement launch logic.**

---

## 2. Repo 1 — the fork (`ChronoAIProject/codex`)

**Purpose:** the only code surface we can write to; a staging area for branches
destined for `openai/codex`.

**Structure:**
- Directory layout **identical to upstream** (`codex-rs/`, `docs/`, …). We never add our own files here.
- Branches: `main` (fast-forward-only **mirror** of upstream) + `fix/<issue#>-<slug>` (one **independent** branch per issue, off `main`).

**Responsibilities:** hold each fix on its own branch (≈2 commits: fail-before/pass-after test + the fix); provide the demo compare-link; be the head of the upstream PR; stay synced (`gh repo sync … --branch main`, rebase live branches, prune merged).

**Does NOT:** commit to `main`; add our own files/docs/harness code; merge fix
branches together or run an internal rollup; hold issues/state/config. (The real
merge happens **upstream** when Codex accepts the PR.)

---

## 3. Repo 2 — `fkst-codex-harness` (HOST repo / control plane)

**Purpose:** the codex-specific host that **composes** the platform and drives the
work. It is the **project-root** the engine supervises (control plane ≠ target).
Modeled exactly on `fkst-website` (a host repo that composes the platform + carries
its own small package).

**Structure (host-repo layout):**
```
fkst-codex-harness/
  fkst.workspace.toml          # declares fkst-packages-platform as external source
  fkst.lock                    # PINS the platform packages source + artifacts
  .fkst-substrate-ref          # PINS the engine (fkst-substrate) build
  .fkst/
    local-packages/<codex-glue>/   # codex-SPECIFIC package(s) only (if any)
    compose/package-roots          # host composition roots (ADR 0002)
    conformance/allowlists/        # host conformance waivers (ADR 0002)
    env.example                    # config: targets, gate policy, device identity
  data/                        # seed corpus (read by source_ref)
    area_rubric.json · open_issue_clusters.json · worked_on_full.jsonl
  scripts/run.sh               # DELEGATES host-run to the shared contract (no copy)
  docs/                        # findings, methodology, this architecture
```

**Responsibilities:**
- **Compose** the pinned platform (foreign-contribution packages + trio) on the codex target — no vendoring.
- Supply **codex-specific config + seed corpus** (the rubric, clusters, precedent corpus).
- Hold any **codex-only glue** as a host-local package under `.fkst/local-packages/`.
- Own the **saga / work-tracking state** — one control issue per candidate on this repo's tracker.
- Launch via the **shared host-run contract** (`scripts/run.sh supervise`), constructing no `--package-root` and no BIN call itself.

**Does NOT:** hold **generic/reusable** behavior (→ `fkst-packages` PRODUCT plane);
**vendor or copy** the platform (it pins + composes); **reimplement** host-run/launch
logic; contain engine code; commit live runtime state.

---

## 4. Repo 3 — `fkst-substrate` (engine)

**Purpose:** the capability-secured local runtime that executes the harness.

**Structure:** Rust workspace (`crates/fkst-framework`, `fkst-common`,
`fkst-supervisor`, …) — already exists; built locally to a `BIN`.

**Responsibilities:** provide the Lua SDK (`sdk_codex`, `sdk_git`, `raise`, durable
delivery, rate/retry, observe); run `fkst-framework supervise` per device; enforce
metered boundary resources (`codex.process`, `git.process`, `shell.process`, fs,
wall-clock) under no-ambient-authority.

**Does NOT:** contain business behavior (→ packages) or anything codex-specific.

---

## 5. `fkst-packages` — PRODUCT plane (pinned dependency)

**Purpose:** the reusable platform. The **generic foreign-contribution behavior**
(triage/score/dedup over a repo you don't own, gated propose, the saga) belongs
**here** — as new packages or by extending the decomposed `github-devloop-intake` /
`-pr` pieces — so it's conformance-guarded and reusable beyond codex. Also supplies
the trio (`github-proxy`, `consensus`) and shared `libraries/`.

Consumed by the harness via `fkst.workspace.toml` `[[external_sources]]` + `fkst.lock`
(a pinned clone, **not** a repo we fork or vendor).

---

## 6. How they connect (local runtime)

```
fkst-substrate ──build──► BIN
                            │
 project-root = fkst-codex-harness  ── scripts/run.sh supervise (local, per-device)
   composes (pinned, not vendored): fkst-packages PRODUCT (foreign-contrib pkgs + trio)
   + .fkst/local-packages/<codex-glue>
        │
        ├── READ ───────────────────► openai/codex issues          (source_ref)
        ├── manage (git worktrees) ──► fork: branch + fix + push    (the demo branches)
        └── GATED propose ──────────► openai/codex issue/comment + (on invite) PR fork→upstream
```

---

## 7. Separation of concerns (the clean cut)

| Concern | Lives in | Plane |
|---|---|---|
| Runtime / capabilities | `fkst-substrate` (→ BIN) | engine |
| **Generic** foreign-contribution behavior + trio | `fkst-packages` | **PRODUCT** |
| **Codex-specific** config + seed data + saga state + glue | **`fkst-codex-harness`** | **HOST** |
| Launch invariants for one host | shared `host_run.sh` (delegated) | HOST-RUN |
| Code being fixed + fix branches | the **fork** | target |
| Live candidate/saga state | engine durable + GitHub markers | **never committed** |
| The issues being fixed | `openai/codex` (theirs) | `source_ref` |

---

## 8. Principles that keep it clean

1. **The fork is a pristine mirror** — never restructured, never committed to on `main`.
2. **Generic → PRODUCT, codex-specific → HOST** — the harness composes; it doesn't hold reusable logic or vendor the platform.
3. **State only from the program** — no candidate/saga state in any git repo.
4. **Two planes** — owned fork (write freely) vs foreign upstream (read + gated propose).
5. **Control ≠ target** — the harness supervises; the fork is just a resource.
6. **Engine ≠ behavior** — substrate has no codex logic; harness has no engine code.
7. **Merges happen upstream** — the fork stages branches; Codex does the actual merge.

---

*Detail references in this folder: `fkst-codex-harness-architecture.md` (the harness
saga in depth), `codex-contribution-playbook.md` (what wins), `METHODOLOGY.md`
(scoring/calibration), `pilot-results.md` (candidates). Fork branching, sync, rebase
and prune are the fork-maintenance workflow.*
