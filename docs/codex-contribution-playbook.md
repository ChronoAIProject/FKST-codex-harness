<div align="center">

[![English](https://img.shields.io/badge/English-1f6feb?style=for-the-badge)](codex-contribution-playbook.md)&nbsp;[![简体中文](https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-8b949e?style=for-the-badge)](codex-contribution-playbook.zh-CN.md)

</div>

# Codex Contribution Playbook

**One doc:** findings + importance rubric + issue anatomy + DOs/DON'Ts + the loop
constitution. Built to make an autonomous issue-fixing loop produce work the
`openai/codex` team will actually *invite and merge*.

- **Goal:** align a loop to what Codex demonstrably values, not to code volume.
- **Method:** scanned all closed issues on `openai/codex` via GitHub API (`gh`),
  cross-referenced against linked/merged PRs. **Data as of 2026-06-29.**
- **Policy truth:** https://github.com/openai/codex/blob/main/docs/contributing.md
  — contributions are **invitation-only**; uninvited PRs are *closed without review*.

---

## TL;DR

- "Important to Codex" = **fixed by a linked PR (614, ~7% of closed)**, NOT
  closed-as-completed (5,316 "completed" closures had zero code change).
- Fixes concentrate in **`exec` / `regression` / `TUI` / `mcp` / `hooks`**; the
  Tier-D areas (`app`, `model-behavior`, `rate-limits`, `safety-check`, …) are graveyards.
- **Default to bugs** — fixed on merit, demand-independent. Features are a roadmap lottery.
- Winning issues are **concise (~200 words) + version + repro**; root cause at
  `file:line` is the loop's edge.
- Outsiders win: **81%** of fixed issues were filed by people with no prior standing;
  **~57%** of fixes are external-authored; **22%** are self-fixed by the filer.
- Optimize **invitation-rate** and the **self-fix path**, never PR-count.
- Issue-first, wait for the invite, never mass-post.

---

## 1. Headline findings

| Metric | Value | Meaning |
|---|---|---|
| Closed issues | 8,871 | the corpus |
| Open issues | 7,700 | the backlog |
| Closed `completed` | 5,861 (66%) | **misleading** signal |
| Closed `not_planned` | 1,457 (16%) | rejected |
| Closed `duplicate` | 1,553 (17.5%) | redundant |
| **Linked to a PR ("worked on")** | **614 (6.9%)** | the real signal |
| **Closed by a *merged* PR (fixed)** | **339** | code actually shipped |
| `completed` but NO linked PR | 5,316 | closed without code — **junk** |
| Assigned to a team member | 230 (2.6%) | team took explicit ownership |

**The three findings that change everything**

1. **"Completed" is noise; "fixed by a linked PR" is truth.** Only ~614 issues
   (6.9%) were ever worked on; 339 fixed by a merged PR. That small set defines
   importance — not the 5,861.
2. **The team does not open public issues** (0 by OWNER/MEMBER; 38 by COLLABORATOR).
   Roadmap is internal → infer it from **merged PRs + CHANGELOG**, not issues.
3. **A measurable trust ladder:** prior contributors get **73.7%** completion vs
   **65.5%** for outsiders. Earning contributor status pays off.

---

## 2. Importance rubric — fix-rate by area

"How likely is an issue in this area to get worked on?" (fixed ÷ closed, areas
with ≥40 closed). Machine-readable: `area_rubric.json`.

### 🟢 TIER A — target aggressively
| Area | fix-rate | fixed/closed |
|---|---|---|
| `exec` | 20.2% | 18/89 |
| `regression` | 20.0% | 16/80 |
| `documentation` | 17.7% | 22/124 |
| `hooks` | 15.1% | 8/53 |
| `TUI` | 14.8% | 145/981 |
| `mcp` | 14.7% | 45/307 |
| `custom-model` | 12.4% | 14/113 |
| `config` | 10.4% | 14/134 |

### 🟡 TIER B/C — only with strong, quantified evidence
`sandbox` 7.6% · `bug` 7.3% · `code-review` 7.3% · `tool-calls` 6.6% ·
`skills` 6.5% · `CLI` 6.0% · `enhancement` 5.6% · `windows-os` 4.7%

### ⚫ TIER D — graveyards, do NOT spend effort here
`context` 2.8% · `auth` 2.7% · `extension` 2.4% · `connectivity` 1.6% ·
`browser` 1.2% · `codex-web` 1.1% · `app` 0.9% · `model-behavior` 0.5% ·
`rate-limits` 0.5% · `safety-check` 0% · `computer-use` 0%

**Read on two axes:** odds (fix-rate) favors `exec`/`regression`/`TUI`/`mcp`/`hooks`;
volume (absolute fixes) favors `bug` 436, `TUI` 145, `enhancement` 131, `CLI` 124,
`windows-os` 55, `mcp` 45, `sandbox` 38. **Sweet spot (both): `regression`, `exec`,
`TUI`, `mcp`.**

---

## 3. Anatomy of a fixed issue (the 614 worked-on set)

**Who files them**: 81% pure outsiders (NONE), 16% prior contributors, 2% team —
the gate is real but **not sealed**.

**Who writes the fixing PR**: team 38%, **issue author self-fix 22%**, other
external 35% → **~57% of fixes are external-authored.** The self-fix path
(file great issue → invited → fix it yourself) is the loop's end-to-end template.

**Body anatomy** (share of the 614):

| Element | Share | Verdict |
|---|---|---|
| Version / semver | **71%** | near-mandatory |
| Repro steps | **71%** | near-mandatory |
| OS / environment | 44% | strongly helps |
| Code block (```) | 42% | strongly helps |
| Log / stack trace | 30% | helps |
| Explicit "expected & actual" | 16% | nice-to-have |
| Screenshot / image | 14% | nice-to-have |

**Length:** median **~200 words** (1,221 chars), p90 ~3,655. Concise + reproducible
beats essays.

**Bugs vs enhancements** — the decisive split:
- **Bugs (436):** median **0 reactions**; **64% had zero reactions and were fixed
  anyway** → fixed on technical merit, demand NOT required.
- **Enhancements (131):** demand doesn't predict fixes (most fixed features had
  <10 reactions); gated by unobservable internal roadmap. **A lottery — default to bugs.**

### The data-derived winning-issue template

```
Title: <area>: <specific symptom>          e.g. "TUI: output truncated on scroll"

**Version:** codex 0.xx.x   **OS:** macOS 14 / Windows 11 / Ubuntu 22   (71% + 44%)

**Steps to reproduce:**                      (71%)
1. ...
2. ...

**Expected:** ...
**Actual:** ...  <paste log / stack trace>   (30% include logs)

```<code/config that triggers it>```          (42%)

**Root cause (if known):** <file:line + mechanism>   ← the loop's edge

Keep it ~200 words.
```

### Exemplars to read (gold standard)

Bugs/regressions: [#2558](https://github.com/openai/codex/issues/2558) (TUI truncation),
[#2860](https://github.com/openai/codex/issues/2860) (Windows perm spam),
[#29189](https://github.com/openai/codex/issues/29189) (MCP/sandbox),
[#2137](https://github.com/openai/codex/issues/2137),
[#4707](https://github.com/openai/codex/issues/4707).
High-demand features that won: [#2890](https://github.com/openai/codex/issues/2890)
(406 reactions), [#2798](https://github.com/openai/codex/issues/2798),
[#2129](https://github.com/openai/codex/issues/2129).
Full text in `_exemplars.json`; all 614 bodies in `worked_on_full.jsonl`.

---

## 4. ✅ DOs

- Measure importance as **fixed-by-linked-PR**, never `state_reason=completed`.
- Target **Tier A** first: `exec`, `regression`, `TUI`, `mcp`, `hooks`.
- **Prioritize regressions** (20% fix-rate): auto `git bisect` to the introducing PR and cite it.
- Use the **doc-fix wedge** (`documentation` 17.7%, low-risk) to climb NONE→CONTRIBUTOR, then attack core bugs.
- Lead with **verifiable repro + root cause at `file:line`** — the hard part is diagnosis, not code.
- **Dedup hard** against the whole corpus — 17.5% of closures were duplicates.
- **Quantify impact** — duplicate-cluster size, reactions, severity, regression, workaround.
- Present approach as **options + defer** ("happy to implement whichever you prefer").
- **Cite their precedent** — an analogous merged PR or a maintainer's stated direction.
- Name **system constraints** unprompted: sandbox boundary, config back-compat, cross-platform, no new deps.
- Keep a **human as the account's voice** (loop drafts, human posts).
- **Infer roadmap from merged PRs + CHANGELOG** (no team-opened issues exist).
- **Wait for an explicit invitation** before any PR; CLA comment: `I have read the CLA Document and I hereby sign the CLA`.
- **Emit the winning format** — version + repro near-mandatory; ~200 words.
- **Aim for the self-fix path** (22% of wins; the only end-to-end route the loop controls).
- **Default to bugs** — merit decides; include a code block / log when relevant.

## 5. ⛔ DON'Ts

- **Don't open uninvited PRs** — closed without review; at scale = spam → ban risk.
- **Don't trust "completed"** as evidence the team cared (5,316 had no code change).
- **Don't file in Tier-D graveyards** (`app`, `model-behavior`, `rate-limits`, `codex-web`, `browser`, `extension`, `auth`, `context`, `safety-check`, `computer-use`).
- **Don't propose enhancements casually** — #1 rejected category; require overwhelming demand.
- **Don't mass-post** — cap public engagement (≤3/day) and always disclose AI assistance.
- **Don't mine "team-opened issues" for roadmap** — that data doesn't exist.
- **Don't submit large/refactor PRs, rename/lint churn, new deps, or scope creep.**
- **Don't post security issues publicly** — email security@openai.com.
- **Don't assert alignment you can't prove** — infer + defer.
- **Don't gate bug-filing on community demand** — irrelevant for bugs.
- **Don't write essays** — length is not a quality signal.

---

## 6. Who grants invitations (team triagers, by assigned issues)

`bolinfest`, `gpeal`, `pakrym-oai`, `etraut-openai`, `fcoury-oai`,
`joeytrasatti-openai`, `easong-openai`, `dylan-hurd-oai`, `aibrahim-oai`,
`jif-oai`, `ccy-oai`, `dedrisian-oai` — ~12 active owners. This is the audience
your issues must convince.

---

## 7. Loop constitution (what the loop LOADS)

Operating contract. Every escalation must pass the §7.4 gates and produce §7.5 output.

### 7.1 Codex's goals (priority-ordered)
- **G1 — Diagnosis is the hard part.** "identifying the right solution is the hard
  part; implementing it is comparatively straightforward." → The loop's product is
  ANALYSIS (repro + root cause + approach); code is the cheap last step, only when invited.
- **G2 — Architectural coherence over throughput.** They gate because contributors
  lack "architectural context, system-level constraints, near-term roadmap." → Acquire
  that context (§7.2) before proposing.
- **G3 — Prioritization = community + roadmap + cross-platform.** Empirically (§2/§3):
  bugs fixed on merit; enhancements are a roadmap lottery → default to bugs.
- **G4 — Invitation-only.** Never open a PR without a recorded maintainer invitation.
- **G5 — Selective, low-noise.** Low-volume, deduped, disclosed. Spam is anti-aligned.

### 7.2 Context acquisition (run FIRST — closes the information-asymmetry gap)
Build a `direction-model.json` from observable signals: architecture/crate layout +
sandbox boundary + config schema + `codex --help`; last ~100 merged PRs + CHANGELOG +
milestones (inferred roadmap); fix conventions + `just` targets; per-issue priority
signals (reactions, dup-cluster, labels). Refresh weekly.

### 7.3 Scoring + empirical tuning
Base weights: problem_understood 30 (reproduced? root cause at file:line?),
approach_alignment 25 (matches patterns + low blast radius + 0 new deps + 0 unintended
behavior change), impact_community 20, roadmap_fit 15, cross_platform 10.
`reproduced=false` ⇒ HARD GATE (drop / needs-info).

**Empirical overrides (take precedence):**
- Target filter BEFORE scoring: type ∈ {bug, regression}; area ∈ Tier A; drop Tier D.
- Boosters: is_regression (top priority + bisect); body has version+repro (near-mandatory);
  root cause at file:line (differentiator).
- **Target metric: invitation-rate + self-fix path. Never PR-count.**
- Format prior: ~200 words, emit the §3 template verbatim.

Alignment is NOT asserted by the loop — it's resolved in the thread and confirmed by the invite.

### 7.4 Hard gates (refuse — no exceptions)
- **gate0** security/safety ⇒ DO NOT post; email security@openai.com.
- **gate1** not reproduced / no root cause ⇒ may not escalate.
- **gate2** HUMAN GATE: nothing posted to the public repo without per-item human approval.
- **gate3** no PR without a recorded maintainer invitation.
- **gate4** volume cap ≤3 new public engagements/day.
- **gate5** duplicate guard: don't repeat an existing comment; append only if adding signal.
- **gate6** touches sandbox/security/config-schema/public API ⇒ HIGH risk, human sign-off even to comment.
- **gate7** disclose AI assistance on every public post.

### 7.5 Output contract
**Issue/comment** (after human approval): repro (version/OS/cmd/expected-vs-actual) ·
root cause file:line · impact (reactions/dups/severity/regression/workaround) ·
approach as options + defer · AI-disclosure.
**PR** (only after invitation): focused branch off main · atomic commits (each
compiles+tests) · fail-before/pass-after test · docs/`--help` updated if user-facing ·
`just fmt && just fix && just test` clean · PR template What/Why/How + linked issue ·
model-metadata changes set `input_modalities` + tests · CLA comment.

---

## 8. Data artifacts (kept alongside this doc)

| File | Contents |
|---|---|
| `area_rubric.json` | machine-readable importance rubric (fix-rate, tiers, rules) |
| `worked_on_full.jsonl` | the 614 worked-on issues — full bodies + closing PRs |
| `worked_on.jsonl` | the 614 worked-on issues — metadata only |
| `codex_closed_issues.jsonl` | all 8,871 closed issues — metadata |
| `_exemplars.json` | selected exemplar bug/regression issues, full text |

## 9. Recommended next step

Assemble a labeled train/test split — `worked_on_full.jsonl` (wins) + a sample of
`not_planned` issues (losses) — so the loop's scorer learns the win/loss boundary
from real examples instead of heuristics.

*Data current as of 2026-06-29.*
