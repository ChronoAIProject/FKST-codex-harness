<div align="center">

[![English](https://img.shields.io/badge/English-1f6feb?style=for-the-badge)](METHODOLOGY.md)&nbsp;[![简体中文](https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-8b949e?style=for-the-badge)](METHODOLOGY.zh-CN.md)

</div>

# Methodology — Codex Issue Triage & Scoring Pipeline

Reproducible record of how we go from "8.8k closed + 7.7k open issues" to a
calibrated, deduped shortlist of attemptable open issues. All steps are read-only
GitHub API calls (`gh`) + local Python (no paid services, no sklearn/numpy).

- **Closed-issue scan:** 2026-06-29 · **Open-issue + pilot run:** 2026-06-30
- **Repo:** `openai/codex` · **Auth:** `gh` (5,000 req/hr)

---

## 0. Pipeline at a glance

```
                 ┌─ closed issues (8,871) ──┐
 DATA PULL ──────┤  open issues   (7,651)   ├── all via gh REST/GraphQL
                 └─ merged PRs    (284)     ┘
        │
        ▼
 IMPORTANCE SIGNAL   "fixed by a linked PR" (614), NOT state_reason=completed
        │
        ▼
 RUBRICS (R1–R4)  ←  derived from fix-rate-by-area + merged-PR profile
 HYPOTHESES (H1–H5) ← what a merged PR looks like
        │
        ▼
 SCORING FUNCTION  score = area_tier + type + anatomy + demand
        │
        ▼
 CALIBRATION   score 614 winners vs 1,457 rejected → AUC + per-bin PR-linked rate
        │
        ▼
 FILTER FUNNEL  hard-drops → bins → ATTEMPT gate → dedup → key-area narrowing
        │
        ▼
 OUTPUT   ranked working candidates (853 in key areas; 54 high-confidence)
```

---

## 1. Data acquisition

| Set | Query | Fields | File |
|---|---|---|---|
| All closed issues | `GET /repos/openai/codex/issues?state=closed --paginate`, filter out PRs (`has("pull_request")`) | number, author_association, state_reason, labels, assignees, comments | `codex_closed_issues.jsonl` |
| Worked-on (PR-linked) | `search/issues q="state:closed linked:pr"` then GraphQL `closedByPullRequestsReferences` | + full body, reactions, closing PR (number, merged, author) | `worked_on.jsonl`, `worked_on_full.jsonl` |
| Open issues | `GET /repos/openai/codex/issues?state=open --paginate`, filter PRs | number, title, body[:600], labels, reactions, comments | `open_issues.jsonl` |
| Rejected (negatives) | `state_reason==not_planned` → GraphQL | full body, labels, reactions | `not_planned_full.jsonl` |
| Merged PRs | GraphQL `pullRequest` on the 324 closing PRs | additions, deletions, changedFiles, commits, author_association | `merged_pr_stats.json` |

GraphQL is batched ~35–40 aliased nodes/request to stay well under rate limits.

---

## 2. Importance signal (the key definition)

**Importance = the issue was closed by a *linked* PR (ideally merged), NOT
`state_reason=completed`.** Rationale: of 5,861 "completed" closures, **5,316 had
no linked PR** (closed without code) → "completed" is noise. Only **614 (6.9%)**
were ever worked on; **339** closed by a merged PR; **545** completed + linked.

---

## 3. Rubrics (derived from past results)

- **R1 Area tier** = fix-rate ÷ closed, per label (≥40 closed). `area_rubric.json`.
  - A: `exec regression TUI mcp hooks custom-model documentation config`
  - B/C: `bug sandbox code-review tool-calls CLI windows-os` (+others 3–8%)
  - D (drop): `app model-behavior rate-limits codex-web browser extension auth context safety-check computer-use`
- **R2 Type:** bug/regression default-eligible; enhancement excluded unless heavy demand.
- **R3 Issue-quality scorecard:** reproduced (hard gate) · root cause at `file:line` ·
  version/OS · repro steps · code/log · concise (~200 words).
- **R4 PR-mergeability:** ≤3 files / ≤200 LOC · 1–2 commits · test fail-before/pass-after ·
  clean `just fmt/fix/test` · trusted author.

---

## 4. Hypotheses on what gets MERGED (evidence: 284 merged PRs)

| # | Hypothesis | Evidence |
|---|---|---|
| H1 | Small & surgical | median 2 files / 80 LOC; 64% ≤3 files; 77% ≤200 LOC |
| H2 | Bug in a high-fix-rate area, not a feature | fix concentration in Tier-A; 0-reaction bugs still merge |
| H3 | PR rides a well-diagnosed issue | 71% of fixed issues had repro + version |
| H4 | Author has earned trust | 283/284 merged PRs by COLLABORATOR/CONTRIBUTOR; 1 by NONE |
| H5 | Atomic & test-backed | median 2 commits; 43% single-commit |

H1/H4/H5 apply at PR/author stage; H2/H3 + demand drive issue-triage scoring (§5).

---

## 5. Scoring function (exact)

Applied to each issue on **body truncated to 600 chars** (parity between
calibration sets and open issues). Labels drive area/type; body drives anatomy.

```
HARD DROPS (return SKIP, score 0):
  - label ∈ {safety-check, security}        → SKIP-security (route to security@openai.com)
  - best area tier == D                     → SKIP-tierD

area_tier  : A=40 · B=24 · C=12 · unknown=8        (best tier among the issue's labels)
type       : regression +24
             elif bug +14
             elif enhancement: 12 if reactions≥30 else 6 if reactions≥10 else 1
             else +6
anatomy    : (cap 25)  version|semver +5 · repro/"steps to" +8 · code ``` +4 ·
             OS(macos|windows|linux) +3 · error|panic|stack|exception +5
demand     : min(reactions,40)/40 × 8

score = area_tier + type + anatomy + demand          (max ≈ 97)

BINS:
  ATTEMPT   if score≥58 AND tier∈{A,B} AND (bug|regression) AND repro_ok
  CANDIDATE if score≥45
  LOW       if score≥32
  SKIP      otherwise
  where repro_ok = (anatomy≥8) OR version/semver present
```

Note: `area_tier` uses the issue's **best** label (a Windows/app issue that is also
a regression qualifies via the regression label — intentional, since regressions
are fixed across all areas). A stricter "primary-area" variant is a tunable option.

---

## 6. Calibration (validates the score predicts approval)

- **Positives:** 614 worked-on (PR-linked) issues, full body. **Negatives:** 1,457
  rejected (`not_planned`), full body. Same scoring function.
- **AUC = 0.730** (rank statistic; 0.5 random, 1.0 perfect).
- Median score: winners **54** vs rejected **41**.
- **Per-bin PR-linked rate (monotonic ⇒ bins are predictive):**
  ATTEMPT **57%** · CANDIDATE 36% · LOW 18% · SKIP 14%.
- Winners: 73% in ATTEMPT+CANDIDATE. Rejected: 60% in SKIP+LOW.

Re-run this whenever weights change; require AUC ≥ ~0.70 and monotonic bin rates.

---

## 7. Duplicate detection (dedup)

Pure-Python TF-IDF cosine with rare-token blocking:
- Text = title (weight ×3) + body[:600]; tokens `[a-z0-9]{3,}`, stopwords removed.
- `idf = log(N/df)`; weight `(1+log(tf))·idf`; L2-normalized vectors.
- Blocking inverted index on tokens with `2 ≤ df ≤ 400`; candidate neighbors =
  docs sharing any of a doc's top-10 highest-idf tokens.
- Edge if cosine **≥ 0.55**; cluster via union-find; representative = most reactions.
- Result: 96 clusters, 264 issues (3% of open), 168 redundant. **High-precision /
  conservative** — true dup rate ≈17.5% (from closed history), so a recall pass at
  ~0.42 (+ embeddings) would surface semantic dupes. Output `open_issue_clusters.json`.

Dedup is applied to the candidate list by collapsing cluster members to the representative.

---

## 8. The filter funnel (open issues → candidates)

```
7,651 open
  − security/safety           −74      → security@openai.com
  − Tier-D area                −5
  SKIP (score<32)             985
  LOW  (32–45)              1,282
  CANDIDATE (45–58)         4,222
  ATTEMPT (≥58 +A/B +bug|regr +repro)  1,083
  − dedup to representatives          → 1,046  working candidates
  ∩ key areas (Tier-A)               →   853
     · score ≥70 (solid)             →   235
     · score ≥75 (high-confidence)   →    54
```

**Key areas (Tier-A):** `exec regression TUI mcp hooks custom-model documentation config`.
**Sweet spot:** `regression exec TUI mcp`.

---

## 9. Outputs

| File | Contents |
|---|---|
| `scored_open_issues.json` | all 7,651 open issues: score, bin, breakdown, dup_of |
| `working_candidates.json` | 1,046 deduped ATTEMPT, score-sorted |
| `key_area_candidates.json` | 853 deduped ATTEMPT in Tier-A areas |
| `open_issue_clusters.json` | 96 duplicate clusters, full membership |
| `area_rubric.json` | fix-rate-by-area rubric + tiers |
| `merged_pr_stats.json` | size/commits/author of 284 merged PRs |

---

## 10. Tunables & caveats

- **Thresholds:** score bins (58/45/32), dedup cosine (0.55), demand cap (40),
  anatomy weights. Recalibrate (§6) after any change.
- **Prefilter, not verdict:** AUC 0.73 ranks well but the final go/no-go needs the
  live R3 hard gate (real reproduction + root cause), done per-issue.
- **600-char body window:** anatomy may under-detect features appearing later in long bodies.
- **Best-label area:** consider a stricter primary-area filter to drop Tier-D co-labels.
- **Dedup recall:** 0.55 is conservative; lower + embeddings for a fuller dup map.
- **Freshness:** issue/PR state drifts; re-pull before acting. Data as of 2026-06-29/30.

---

## 11. Re-run order

1. Pull closed + open + worked-on + not_planned + merged-PR data (§1).
2. Compute fix-rate rubric → `area_rubric.json`.
3. Score positives/negatives → calibrate (§6); accept if AUC ≥0.70 & monotonic.
4. Cluster open issues (§7).
5. Score + bin open issues (§5), apply funnel (§8) → candidate files (§9).

*See `codex-contribution-playbook.md` (findings + DOs/DON'Ts), `pilot-results.md`
(this run's results). Data as of 2026-06-29 / 2026-06-30.*
