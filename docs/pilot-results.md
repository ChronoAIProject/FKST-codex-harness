# Pilot Run — Rubrics, Merged-PR Hypotheses & Open-Issue Duplicate Detection

Pilot executed 2026-06-30 against `openai/codex`. Inputs: the findings in
`codex-contribution-playbook.md` + live pull of all open issues and the merged PRs
that closed the 614 worked-on issues. All read-only.

**What ran:** (A) formed 4 rubrics from past results · (B) profiled 284 merged PRs →
top-5 hypotheses on what gets merged · (C) clustered all 7,651 open issues to find
duplicate buckets.

---

## A. Rubrics (derived from recorded results)

**R1 — Area tier** (from `area_rubric.json`, = fix-rate ÷ closed)
- A (hunt): `exec` `regression` `TUI` `mcp` `hooks` `custom-model` `documentation` `config`
- B/C (only with strong evidence): `bug` `sandbox` `code-review` `tool-calls` `CLI` `windows-os`
- D (drop): `app` `model-behavior` `rate-limits` `codex-web` `browser` `extension` `auth` `context` `safety-check` `computer-use`

**R2 — Issue type:** bug/regression = default-eligible; enhancement = excluded unless
overwhelming demand (features are a roadmap lottery; 64% of fixed bugs had 0 reactions).

**R3 — Issue quality (the anatomy scorecard, 0–100):** reproduced (hard gate) ·
root cause at `file:line` · version+OS present (71% of winners) · repro steps (71%) ·
code/log block (42%/30%) · concise (~200 words). Below threshold ⇒ not escalatable.

**R4 — PR mergeability (NEW, from §B):** small (≤3 files / ≤200 LOC) · atomic
(1–2 commits) · test fail-before/pass-after · clean `just fmt/fix/test` · author has
earned contributor status.

---

## B. Top-5 hypotheses: what the team wants in a MERGED PR
*(profiled 284 merged PRs that closed worked-on issues)*

| # | Hypothesis | Evidence | Implication |
|---|---|---|---|
| **H1** | **Small & surgical wins** | median **2 files / 80 LOC**; 64% ≤3 files, 77% ≤200 LOC, 33% ≤1 file | Cap PRs at ~3 files / 200 LOC; large PRs ≈ won't merge |
| **H2** | **Bug fix in a high-fix-rate area, not a feature** | fixes concentrate in Tier-A; bugs fixed on merit (0-reaction bugs still merge) | Target Tier-A bugs/regressions; avoid features |
| **H3** | **PR rides a well-diagnosed issue** | "diagnosis is the hard part"; 71% of fixed issues had repro + version | Land the issue (repro + root cause) first; PR is the easy follow-on |
| **H4** | **Author has earned trust** | **283/284 merged PRs were COLLABORATOR/CONTRIBUTOR; only 1 from NONE** | Climb NONE→CONTRIBUTOR via the doc-fix wedge before expecting bug-fix merges |
| **H5** | **Atomic & test-backed** | median **2 commits, 43% single commit**; bug fixes ship with tests | One logical change, fail-before/pass-after test, green `just` checks |

> H4 is the sharpest: direct merges from pure outsiders are vanishingly rare (1 in 284).
> The realistic path is **file excellent issues → earn contributor standing → then merge fixes.**

---

## C. Open-issue duplicate detection

**Method:** TF-IDF cosine over title (weighted 3×) + body excerpt, rare-token blocking,
union-find clustering, cosine threshold **0.55** (high-precision / conservative).

**Headline:**
- Open issues scanned: **7,651**
- Duplicate clusters (≥2): **96**
- Issues sitting in a duplicate cluster: **264 (3% of open)**
- Redundant issues (beyond 1 representative per cluster): **168**

**By rubric tier** (cluster's best-tier label):

| Tier | open issues | dup clusters | redundant |
|---|---|---|---|
| A | 1,418 | 7 | 8 |
| B | 5,313 | 82 | 152 |
| C | 909 | 7 | 8 |
| D | 5 | 0 | 0 |

*(Most clusters land in B because the `bug` label itself is Tier-B; the area sub-label
determines true value — see actionable list.)*

**⚠️ This is a conservative floor.** At 0.55 we catch near-identical wording only.
Closed-issue history shows the *true* duplicate rate is ~17.5%, so semantic duplicates
(same bug, different phrasing) are being missed. A recall pass at ~0.42 + an embedding
model would surface more. For a pilot this set is high-precision and safe to act on.

### Top actionable duplicate clusters (Tier A/B — prime targets)

| Tier | size | reacts | area | representative |
|---|---|---|---|---|
| **A** | 3 | 36 | `mcp` | #6020 — MCP client failed to start: handshake failed |
| B | 14 | 13 | `app` | #29211 — Node REPL broken: sandboxPolicy missing in MCP meta |
| B | 8 | 54 | `connectivity` | #15046 — remote compact: stream disconnected before completion |
| B | 7 | 11 | `windows-os` | #27287 — Computer Use bootstrap fails on Windows (@oai/sky) |
| B | 7 | 5 | `connectivity` | #23842 — Stream disconnected: Transport/network error |
| B | 6 | 15 | `extension` | #17765 — Remote-SSH uses global /tmp/codex-ipc on multi-user |
| B | 5 | 13 | `windows-os` | #25197 — notification click opens invalid WindowsApps path |
| B | 4 | 19 | `app` | #30224 — "model not supported" w/ X-OpenAI-Internal header |

Full membership (all 96 clusters, every member issue #) in `open_issue_clusters.json`.

---

## D. What the pilot demonstrates

1. The rubrics + clustering run end-to-end on the live repo with no paid services.
2. The **`mcp` cluster #6020** (Tier-A area, 36 reactions, 3 dupes) is a textbook
   pilot target: high-value area + community demand + dedupable → a single consolidated
   repro + root-cause dossier could earn engagement and start the self-fix path.
3. Dedup directly attacks the #1 avoidable failure (17.5% of closures are duplicates):
   consolidating a cluster into one strong issue is itself a welcome contribution.

## E. Recommended next steps

1. **Recall pass:** rerun clustering at threshold ~0.42 (+ optional embeddings) to
   estimate the true duplicate rate and catch semantic dupes.
2. **Draft a consolidated dossier** for 1–2 top Tier-A/B clusters (e.g. #6020 `mcp`)
   using the R3 scorecard — repro + root cause at `file:line` + "represents N dupes."
   Human-gated before any posting.
3. **Wire R1–R4 into the loop scorer** as the target filter + mergeability check.

## F. Hypothesis-based scoring of open issues + calibration

**Scoring function** (operationalizes the rubrics on issue-observable features):
- Area tier (R1/H2): A=40 · B=24 · C=12 · D=drop
- Type (R2/H2): regression +24 · bug +14 · enhancement +1…12 (by demand)
- Anatomy (R3/H3): version + repro + code + OS + logs (cap 25)
- Demand: reactions (cap 8)
- *(H1/H4/H5 are PR/author-stage — applied at fix time, not issue triage.)*

**Calibration — "bin by approved-PR-linked":** scored the 614 PR-linked winners
vs the 1,457 rejected (`not_planned`) issues.
- **AUC = 0.730** (0.5 random) — the score separates winners from losers.
- Median score: winners **54** vs rejected **41**.
- **Per-bin PR-linked rate is monotonic** (the bins are predictive):
  ATTEMPT **57%** · CANDIDATE 36% · LOW 18% · SKIP 14%.
- Winners land 73% in ATTEMPT+CANDIDATE; rejected land 60% in SKIP+LOW.

**Open issues scored (7,651):**

| Bin | count |
|---|---|
| ATTEMPT | 1,083 (1,046 after dedup) |
| CANDIDATE | 4,222 |
| LOW | 1,282 |
| SKIP | 985 |
| auto-dropped (security / Tier-D) | 74 / 5 |

**Top attemptable open issues** (dedup'd to cluster representatives):

| score | tier | area labels | issue |
|---|---|---|---|
| 93 | A | bug, extension, regression | #18993 — can't open past conversation history in VS Code |
| 89 | A | bug, sandbox, regression | #16205 — CLI panics on launch from git worktree dir |
| 82 | A | bug, windows-os, extension | #17649 — [regression] file-reference links in VS Code |
| 82 | A | bug, extension, regression | #7972 — high CPU on macOS after VS Code ext update |
| 81 | A | bug, TUI, regression, perf | #16335 — TUI/CLI performance regression 116→117 |
| 81 | A | bug, CLI, regression | #13555 — fails: missing optional dependency |
| 80 | A | bug, sandbox, regression | #16451 — Linux sandbox regression: denies /dev |
| 80 | A | bug, mcp, sandbox, regression | #13476 — excessive approval prompts after change |

**Caveats:** AUC 0.73 = a strong *triage prefilter*, not a verdict — final go/no-go
still needs the live R3 hard gate (actual repro + root cause at `file:line`), which
the loop runs per issue. The top of the list is regression-heavy by design
(regressions are the highest fix-rate bucket). Dedup applied so the same bug isn't
attempted N times.

**Use:** take the top ATTEMPT representatives → live repro + `git bisect` → draft
the R3 dossier (human-gated before posting).

---

## Data artifacts (this run)
| File | Contents |
|---|---|
| `open_issues.jsonl` | all 7,651 open issues (title, body excerpt, labels, reactions) |
| `open_issue_clusters.json` | the 96 duplicate clusters, full membership |
| `merged_pr_stats.json` | size/commits/author for 284 merged PRs |
| `scored_open_issues.json` | all 7,651 open issues scored + binned + dup_of |
| `not_planned_full.jsonl` | 1,457 rejected issues (negative calibration set) |

*See `codex-contribution-playbook.md` for the full methodology and DOs/DON'Ts.*
