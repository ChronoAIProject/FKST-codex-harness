# Stream Showcase — the FKST loop on `openai/codex`

How to stream the harness at work: the concepts, the chosen sequence, per-beat
wireframes, the hero metric, what is genuinely **live-runnable today** vs. what must
be **pre-recorded**, and a timed run-of-show. _As of 2026-07-01._

Grounded in the repo: `docs/pilot-results.md` (numbers), `docs/learning-model.md`
(the loop's thesis), `packages/codex-saga/core/{consensus,egress,track}.lua`,
`libraries/advocate/gate.lua`, `packages/codex-saga/core/saga_table.lua` (saga order),
and `data/open_issue_clusters.json` (the real issue picks).

---

## 0. TL;DR — the locked decisions

| Decision | Choice | Why |
|---|---|---|
| **Sequence** | **C → B → A** (cold-open → body → finale) | Codex's ranking B>A>C>D, sequenced: context, then craft, then the trust climax |
| **Hero issue** | **#6020** — `mcp` "MCP client failed to start: handshake failed" (Tier-A, 36 reactions, 3-member dup cluster) | Pilot's #1 actionable cluster; **verified present** in `data/open_issue_clusters.json` |
| **Backup issue** | **#15046** — `connectivity` "remote compact: stream disconnected" (54 reactions, highest demand) | Live safety net if the hero won't reproduce in rehearsal |
| **Hero metric** | **the deliberation funnel** (agents judging + refusing), **not** issues-raised | "Issues raised" broadcasts the spammy-bot posture the harness is built *against* (1-in-284) |
| **Safety posture** | `FKST_GITHUB_WRITE` **unset** → dry-run intents only | The whole trust story: it decides to act on a live OpenAI repo and posts nothing |

> ⚠️ **Correction carried in from the design session:** an earlier draft used issue
> `#16205` and a root cause `core/exec.rs:88`. **Neither exists in our data** — they were
> fabricated. This doc uses the *real* pilot picks (#6020 / #15046) and leaves root-cause
> specifics as `‹from dress rehearsal›` placeholders, to be filled by an actual diagnosis
> before air. A stream whose thesis is "grounded + retrievable" cannot show a made-up issue.

---

## 1. The thesis the stream must sell

From `docs/pilot-results.md` (H4, the sharpest finding): **283 of 284** merged
`openai/codex` PRs came from a `COLLABORATOR`/`CONTRIBUTOR`; **exactly 1** from a pure
outsider (`NONE`). Direct merges from strangers are **1-in-284**.

So the harness is **not** a PR-volume machine. It optimizes for *invitation-rate* and a
*self-fix path* — judgment and restraint, not output. Every framing choice below serves
that thesis. It is why the hero metric is **deliberation, not issues raised**: a big
`issues raised: 512` odometer advertises exactly the behaviour that gets uninvited
contributions closed. On stream that is self-sabotage.

---

## 2. Concepts considered + Codex's verdict

Four distinct angles were drafted and routed to the `codex` CLI (read-only sandbox,
grounded in harness facts) for critique.

| | Concept | Angle | Hero moment |
|---|---|---|---|
| **A** | **The Dry-Run Confessional** | trust-first | Decides to act on a live OpenAI repo, prints the exact intent, posts nothing; advocate refuses a candidate on camera |
| **B** | **One Bug, End to End** | craft/narrative | Fork worktree + diagnosis → root cause at `file:line` on one real issue |
| **C** | **Moneyball for 7,651 Issues** | data/method | Scoring + dedup that finds signal at scale (AUC 0.73, 96 clusters, 1-in-284) |
| **D** | **It Gets Smarter** ("The Memory Loop") | learning loop | `relearn` re-fitting rubric/styleguides from outcomes across epochs |

**Codex ranking: B > A > C > D.** Its recommendation was *not* to pick one but to
**sequence three**: cold-open **C** ("we scanned 7,651 — here's *why this one*"), body
**B** (one issue, one worktree, one diagnosis), finale **A** (the gate, advocate dissent,
the dry-run intent body). Working title: **"One Real Codex Issue, Diagnosed End-to-End,
With the Brakes On."** **D** is deferred to **episode 2** (needs real outcomes first, or it
"looks staged").

**Honesty cuts Codex flagged (still binding):** don't imply ambient autonomy is turnkey;
don't promise a live `open_pr` — show it only as dry-run / invitation-gated. See §7 for how
these bind to what is actually implemented.

---

## 3. The screen system (persistent OBS frame)

One 16:9 canvas pushed to YouTube-Live. Three regions are **always on**; the center panel
**swaps per beat**. YT's native chat/super-chat column sits outside this canvas (right of
the player); only Concept A reserves an in-scene chat strip so "it refused itself"
reactions land in the VOD.

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ ● LIVE  One Real Codex Issue, End-to-End   #6020   stage: ▸GATE     round 2/3      │ ← title · issue · stage chip
├──────────────────────────────────────────────────────────────────────────────────┤
│ FKST LOOP ▸ scanned 7,651 → deliberated 12 → ✗refused 4 → cleared 8 →              │ ← DELIBERATION FUNNEL (hero band)
│            engaged 3 → invited 1 → tracked 4        why so picky: 1-in-284          │   src: redb / state labels + advocate outcome
├───────────────┬──────────────────────────────────────────────────────────────────┤
│ LOOP MAP      │                                                                    │
│ triage    ✓   │            ┌──────── CENTER: swaps per beat ────────┐              │
│ diagnose  ✓   │            │  C beat    → scoring / dedup funnel      │              │
│ implement ✓   │            │  B beat    → diagnosis / root cause      │              │
│ dossier   ✓   │            │  GATE beat → deliberation feed ↓         │              │
│ GATE     ◉◄   │            │  A beat    → dry-run intent body         │              │
│ engage    ·   │            └──────────────────────────────────────────┘              │
│ invite_w  ·   │                                                                    │
│ open_pr   ·   │                                                                    │
│ track     ·   │                                                                    │
├───────────────┴──────────────────────────────────────────────────────────────────┤
│  FKST_GITHUB_WRITE=<unset> · DRY-RUN — NOTHING LEFT THIS MACHINE · openai/codex RO │ ← safety bar (whole stream)
└──────────────────────────────────────────────────────────────────────────────────┘
```

The loop map uses the **real** saga order from `core/saga_table.lua`:
`diagnose → implement → dossier → gate → engage → invite_watch → open_pr → track`
(drops: `needs_info`, `blocked`, `refused`, `security_routed`, `needs_invite`).

---

## 4. Wireframes per beat

### 4.1 Concept C — cold open ("Moneyball for 7,651")

Center panel is the narrowing funnel; the point is *why #6020*, not the dashboard itself.

```
├───────────────┬──────────────────────────────────────────────────────────────────┤
│ LOOP MAP      │  SELECTION — scoring + dedup (rubric: area·type·anatomy·demand)   │
│ triage   ◉◄   │  ────────────────────────────────────────────────────────────────│
│               │   7,651 open  ──score──▶  ranked   ──dedup(96 clusters)──▶  picks  │
│               │   AUC 0.730  (separates merge-winners from losers)                 │
│               │  ────────────────────────────────────────────────────────────────│
│               │   TOP TIER-A CLUSTER                                               │
│               │   ► #6020  mcp · handshake failed · 36 reacts · 3 dupes  ★ pick    │
│               │     #15046 connectivity · stream disconnect · 54 reacts (backup)   │
│               │  ────────────────────────────────────────────────────────────────│
│               │   why this one: Tier-A area + real repro surface + live demand      │
└───────────────┴──────────────────────────────────────────────────────────────────┘
```
Data source: `data/open_issue_clusters.json` + the pilot's scored artifacts. Replay the
**pre-computed** pilot output — do **not** crawl 7,651 live issues on air (rate limits, time).

### 4.2 Concept B — body ("One Bug, End to End"), DIAGNOSE beat

The craft beat: fork worktree → reproduce → root cause. ⚠️ **Pre-recorded** — see §7.

```
├───────────────┬──────────────────────────────────────────────────────────────────┤
│ LOOP MAP      │  TERMINAL — fork worktree (ChronoAIProject/codex)   [rehearsed]    │
│ DIAGNOSE ◉◄   │   $ git worktree add ../wt-6020 <sha>                              │
│               │   $ <reproduce MCP handshake per issue #6020>                      │
│               │   ► reproduced: client aborts handshake before capability exchange │
│               │  ──────────────────────────────┬─────────────────────────────────│
│               │  ROOT CAUSE  ★climax           │  FIX PATH                        │
│               │  ‹file:line — from rehearsal›   │  ‹≤3 files · test-backed›         │
│               │  ‹one-line why›                 │  ‹minimal diff — dry-run only›    │
└───────────────┴──────────────────────────────────────────────────────────────────┘
```
If repro *fails*, the honest beat is diagnose dropping to **`needs_info` with a why**
(`diagnose/main.lua:45–47`) — show that too; the honest "no" is part of the credibility.

### 4.3 The GATE beat — the deliberation feed (the live hero)

Genuinely runnable today (`gate/main.lua` + `consensus.lua` + `advocate/gate.lua`).

```
├───────────────┬──────────────────────────────────────────────────────────────────┤
│ LOOP MAP      │  GATE — 3 independent read-only judges          candidate #6020    │
│ GATE     ◉◄   │  ────────────────────────────────────────────────────────────────│
│               │   ▸ alignment     VERDICT: approve   "fits area rubric, real bug"  │ ← consensus.lua:12 angle 1
│               │   ▸ blast_radius  VERDICT: reject  ◄  "‹repro not proven; wide     │ ← consensus.lua:12 angle 2
│               │                                        surface›"                    │
│               │   ▸ devils-adv.   STANCE: dissent  ◄  "‹root cause unproven →        │ ← advocate/gate.lua:34
│               │                                        do NOT engage›"              │
│               │  ────────────────────────────────────────────────────────────────│
│               │   AGGREGATE  unanimous? NO  →  COMBINED VERDICT: ✗ REFUTED         │ ← fail-closed combine(), advocate/gate.lua:63
│               │   effect: dropped at gate → state: refused (no engage)              │
│               │  ────────────────────────────────────────────────────────────────│
│               │   today at the gate:  deliberated 12 · advocate refused 4 ← hero    │
└───────────────┴──────────────────────────────────────────────────────────────────┘
```
Per gate = **3 judgments**: `alignment` + `blast_radius` (both `consensus.lua:12`, each a
read-only codex judge emitting `VERDICT: approve|reject`, aggregated **unanimous-or-refuse,
fail-closed**) **+** the `devils-advocate` dissent angle (`advocate/gate.lua:34`); `combine()`
passes **only if** consensus approves **and** dissent doesn't block, else `refuted`
(`advocate/gate.lua:63`).

**Show both outcomes across the stream:** queue a deliberately-weak candidate that the
advocate legitimately **refuses** (the drama), *and* the hero #6020 that **passes** →
`COMBINED VERDICT: ✓ PASS → engage`. Both real, both from the actual gate.

### 4.4 Concept A — finale ("The Dry-Run Confessional"), ENGAGE beat

```
├───────────────┬──────────────────────────────────────────────────────────────────┤
│ LOOP MAP      │  ENGAGE — first outward action (dry-run)                           │
│ engage   ◉◄   │  ────────────────────────────────────────────────────────────────│
│               │   INTENT (what it WOULD post — nothing sent)                       │
│               │   ┌──────────────────────────────────────────────────────────┐    │
│               │   │ POST → openai/codex#6020                                  │    │
│               │   │ > Repro on ‹ver›; root cause ‹file:line›; fix ≤3 files    │    │
│               │   │ > (AI-assisted — disclosure)                              │    │
│               │   └──────────────────────────────────────────────────────────┘    │
│               │   engine log: "codex-saga dry-run: would comment on openai/codex   │
│               │                (no external write)"                                 │
│               │  ────────────────────────────────────────────────────────────────│
│               │   next: invite_watch → open_pr GATED on invitation (never forced)  │
└───────────────┴──────────────────────────────────────────────────────────────────┘
```
Real path: `engage/main.lua:33,66` → `core.egress_write` records an **intent** unless
`FKST_GITHUB_WRITE=1`. Say it out loud: *"the flag is unset, so nothing left this machine."*

---

## 5. The hero metric — deliberation funnel (not issues raised)

Render deliberation as a **funnel**, never a lone counter — it turns "few outputs" into
*discipline* instead of weakness:

```
FKST LOOP ▸ scanned 7,651 → deliberated 12 → ✗advocate refused 4 → cleared 8
          → engaged 3 → invited 1 → tracked 4        (why so picky: 1-in-284)
```

- **Hero sub-stat: advocate refusals.** "The system said *no* 4 times today" is the single
  most credibility-building number on screen.
- **Per-issue (on the #6020 card):** `deliberations: 3 (align ✓ · blast ✗ · dissent ✓) →
  verdict: refuted` — the live beat when the loop hits `gate`.
- **Keep "issues raised" only as the funnel's *top* number** (scale/context), never the headline.

Why deliberation wins on all three axes: it is **on-thesis** (judgment, not volume);
it is the **differentiator** (every bot raises issues; almost none show a fail-closed
reasoning gate); and it is **better television** (verdicts landing per angle, the advocate's
objection on screen, a candidate dying at the gate — vs. a static odometer).

---

## 6. Retrievability map — what's real in dry-run

Two hard facts from the code that constrain every overlay:

1. **In dry-run there are *no* harness GitHub issues to read.** Creating/commenting on the
   saga control issue goes through the same `core.egress_write` path as foreign writes
   (`engage/main.lua:33`, `core/track.lua`), so with `FKST_GITHUB_WRITE` unset the control
   issue is only an **intent + log line**. The dry-run source of truth is the engine's
   **durable redb** + the **log stream** — not `gh`.
2. **The control issue is born at `engage`, not before** (`engage/main.lua:33`) — so a
   *GitHub-only* scoreboard can't see the pre-engage funnel. But the deliberation signals
   are now captured in the **durable outcomes JSONL** (`core/deliberation.lua`): every gate
   refusal is appended there unconditionally (dry-run-safe), keyed by `dedup_key`, with a
   disposition inert to codex-learn. So the early funnel **is** retrievable — from the
   durable channel, not `gh`.

| On-screen element | Real source | Retrievable in dry-run? |
|---|---|---|
| Funnel counts (deliberated / refused / cleared) | `core.deliberation_stats()` over the durable outcomes JSONL (latest-wins) | ✅ durable JSONL — no write-mode needed |
| Per-angle verdicts (`align`/`blast`/`dissent`) | `consensus_angles` map on the gate/track record (`core/deliberation.lua`, `outcomes_store.lua`) | ✅ durable JSONL; also the control-issue comment on a pass (write-mode) |
| Advocate refusal reason (**the hero stat**) | refusal record at the gate: `disposition=refused_consensus` + `advocate_reason` (`gate/main.lua`) | ✅ durable JSONL now — captured even though a refusal gets no issue |
| Deliberation count (`N`) | `deliberation_count` on each record + `deliberation_stats().deliberated` | ✅ durable JSONL |
| Root cause `file:line`, the diff | diagnose payload + fork branch (payload discipline excludes diffs) | ❌ log stream / fork, never on the control issue |
| `7,651` / `1-in-284` / AUC | `data/` pilot artifacts | ❌ analysis artifacts |

**Net:** the entire funnel band and the whole gate feed are now sourceable from the **durable
outcomes JSONL** in dry-run — no `FKST_GITHUB_WRITE` needed, including the pre-engage refusals
that never become issues. On a pass, the per-angle verdicts + count also render as a logged
string in the control-issue comment (write-mode). Only the aggregate context stats and
root-cause/diffs live elsewhere (`data/`, logs, the fork), never on the control issue.

---

## 7. What is LIVE-runnable today vs. pre-recorded

This is the crux of "so bisect can't cause dead air." The honest reason bisect can't
cause dead air is that **the diagnose repro/bisect path is not implemented yet** — it is
`TODO(Task D/E)` (see `CLAUDE.md`), so it *must* be pre-recorded. What follows is the true
implemented-state, from the code.

| Beat | State in code | On stream |
|---|---|---|
| **Cold open — `scripts/run.sh test`** | ✅ real; verbs are `check`/`test` only | **LIVE** — green today (engine at `../FKST-substrate/target/debug/fkst-framework`; `run.sh` resolves `BIN` via fallback). *Confirm green in dress rehearsal.* |
| **C — scoring/dedup funnel** | ✅ pilot artifacts real (`data/`) | **REPLAY** pre-computed pilot output; do not crawl 7,651 live |
| **B — diagnose: worktree + bisect + `file:line`** | ⚠️ `diagnose/main.lua` has repro-scaffold only; **no `git bisect`**; drops to `needs_info` without a fork checkout (`:35,45`). `TODO(Task D/E)` | **PRE-RECORDED** — run a real diagnosis in dress rehearsal, capture the artifact, replay at speed. Label the panel `[rehearsed]`. |
| **GATE — consensus + advocate deliberation** | ✅ real & unit-tested (`gate/main.lua:12,73–92`, `consensus.lua`, `advocate/gate.lua`; `egress_test.lua`, `saga_test.lua`) | **LIVE** — the genuine hero beat. Run the judges on the fixture subject; verdicts are real. |
| **ENGAGE — dry-run intent body** | ✅ real (`engage/main.lua:33,66` → `core.egress_write`) | **LIVE** — the intent prints; nothing is sent (`FKST_GITHUB_WRITE` unset) |
| **`open_pr` / invitation** | gated; foreign-plane | **DRY-RUN / described only** — never a live `open_pr` on air |
| **`supervise` continuous loop** | ❌ **not a `run.sh` verb** | **DO NOT CLAIM** as turnkey; the single-issue walkthrough is what's stageable today |

**Nondeterminism note (gate judges are LLM calls):** the consensus/advocate judges are real
`codex` calls — latency + variance. For tight timing, **record the verdicts in dress
rehearsal and replay the real recorded text live**, with the option to run them genuinely
live if confident. Everything shown is a real artifact from a real run; the only "baking"
is re-running a rehearsed step so there is no dead air — never fabricating a result.

---

## 8. Run of show (C → B → A, ~30 min)

Legend: **L** = live on air · **P** = pre-recorded/replayed · **R** = replayed pilot artifact.

| Time | Beat | On screen | Command / source | Mode |
|---|---|---|---|---|
| 0:00 | **Open** | Title card + safety bar up | — | L |
| 0:30 | **"It's real, watch it pass"** | Terminal runs the suite green | `scripts/run.sh test` | **L** |
| 2:00 | **C — the problem in numbers** | Pilot scoreboard: 7,651 · AUC 0.730 · 96 clusters · 283/284 | `docs/pilot-results.md` | R |
| 3:00 | **C — why this one** | Scoring→dedup funnel narrows to **#6020** (backup #15046) | `data/open_issue_clusters.json` | R |
| 5:30 | **Hand to B** | Loop map lights `diagnose` | — | L |
| 6:00 | **B — reproduce** | Fork worktree; MCP handshake reproduced | rehearsed capture | **P** |
| 9:00 | **B — root cause (money shot)** | `‹file:line›` + one-line why | rehearsed capture | **P** |
| 12:00 | **B — implement (fix path)** | ≤3 files, test-backed, **dry-run** | rehearsed capture | P |
| 15:00 | **B — dossier** | Retrieve precedent comment/PR exemplars from corpus | `data/corpus_*.jsonl` | R |
| 18:00 | **Hand to A** | Loop map lights `gate` | — | L |
| 18:30 | **A — deliberation feed** | 3 judges: align / blast / dissent land verdicts | `gate` + `consensus` + `advocate` | **L**\* |
| 21:00 | **A — the refusal** | Weak candidate → `COMBINED: ✗ REFUTED`; advocate quote on screen | live/recorded gate | **L**\* |
| 23:30 | **A — the pass** | #6020 → `✓ PASS → engage` | live/recorded gate | **L**\* |
| 25:00 | **A — the climax (dry-run intent)** | `POST → openai/codex#6020` intent body; "nothing left this machine" | `engage` → `egress_write` | **L** |
| 28:00 | **Invitation boundary** | `invite_watch → open_pr` gated on invitation (described) | — | L |
| 29:00 | **Funnel recap** | "deliberated 12 · advocate refused 4 · engaged 3" | redb / log | L |
| 30:00 | **Tease episode 2** | "The Memory Loop" — *after* real outcomes | `docs/learning-model.md` | — |

\* **L**\ = live if judge latency/variance is acceptable in rehearsal; otherwise replay the
real recorded verdicts (see §7 nondeterminism note).

---

## 9. Pre-production checklist (dress rehearsal)

- [ ] `scripts/run.sh test` green end-to-end (engine resolves; suite passes). This is the cold open.
- [ ] **Actually diagnose #6020 off-stream** → capture the real `file:line`, fix path, and repro
      steps; fill the `‹…›` placeholders in §4.2 / §8. If it won't reproduce, switch hero to **#15046**.
- [ ] Prepare the **weak candidate** that the advocate legitimately refuses (for the on-camera "no").
- [ ] Record the **gate verdicts** (align/blast/dissent) for both candidates; keep the real text for replay.
- [ ] Confirm `FKST_GITHUB_WRITE` is **unset** in the streaming env; put the flag state on the safety bar.
- [ ] Build the OBS scene collection (§3 frame + the four center panels as scenes).
- [ ] Decide chat-in-VOD: reserve the right strip **only** for Concept A's finale.

---

## 10. Honesty cuts — do NOT claim on air

- **No live `open_pr`** — dry-run / invitation-gated only.
- **`supervise` is not wired** (`run.sh` has `check`/`test` only) — say plainly the *single-issue
  walkthrough* is what's stageable today; ambient autonomy is not turnkey.
- **`diagnose` bisect is `TODO(Task D/E)`** — the B beat is a rehearsed capture, not a live crawl.
- **In dry-run there are no real harness issues** — the funnel/gate data is redb + logs, not `gh`.
- **Don't oversell "learning"** — defer the Memory Loop (D) to episode 2, after real outcomes exist.

---

## Provenance

Numbers: `docs/pilot-results.md`. Loop thesis: `docs/learning-model.md`. Saga order & gate
mechanics: `packages/codex-saga/core/saga_table.lua`, `core/consensus.lua`, `core/egress.lua`,
`libraries/advocate/gate.lua`, `packages/codex-saga/departments/{diagnose,gate,engage}/main.lua`.
Issue picks: `data/open_issue_clusters.json`. Design critique: `codex` CLI, read-only sandbox,
2026-07-01.
