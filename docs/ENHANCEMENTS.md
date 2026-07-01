# Enhancements & deferred work — fkst-codex-harness

A running backlog of "come back to this later" items. Each entry carries enough context to
pick up cold: the gap, the approach, and the files involved. _Newest first._

---

## E1 — Make the gate's per-angle deliberation a learning / tuning goal

**Status:** deferred · **Area:** codex-learn (calibration) + codex-saga (gate) · _Filed 2026-07-01._

### The gap
The gate records rich deliberation signals — the per-angle consensus verdicts
(`consensus_angles`: `alignment` / `blast_radius`) + the devil's-advocate dissent, plus a
`deliberation_count` — to the durable §5 outcomes channel (`core/deliberation.lua`,
`departments/gate/main.lua`). But `codex-learn` does **not** consume them
(`grep -r consensus_angles packages/codex-learn` is empty). So today the loop learns from the
advocate's **combined** verdict (`calibrate_advocate` scores `advocate_verdict` vs the actual
`disposition`), but it **cannot learn which individual consensus angle predicts wins**.

Concretely: if `blast_radius` keeps rejecting picks that later merge, the harness *has* the data
to notice (`consensus_angles.blast_radius == "reject"` on a `disposition == "merged"` record) —
but nothing acts on it. The deliberation capture is recorded, not yet *tuned against outcomes*.

### The success criterion it closes on
The existing win/loss signal (`relearn.lua` `disposition_label`): **win** = `merged` OR
`invited`/`positive`; **loss** = `closed` / `ignored`. Per-angle calibration scores each angle
against that *same* signal.

### Recommended approach
Extend `codex-learn/core/calibrate.lua` (or a sibling `calibrate_angles`) to, per resolved
outcome, compare each `consensus_angles[angle]` against `is_good` / `is_bad`:
- angle said **reject** but the pick **won** → that angle is **too strict** (false-strict);
- angle said **approve** but the pick **lost** → that angle is **too lenient** (false-lenient).

Aggregate per-angle reliability across resolved outcomes and emit a per-angle weight /
recommendation into the rubric (alongside `advocate_calibration`), so the gate can down-weight
a chronically-wrong angle or surface it. Mirror the existing discipline: **fail-closed** and
**resolved-only** (only `merged|closed|ignored` count; skip in-flight / dispositionless).

### Touch points
- `packages/codex-saga/core/deliberation.lua` — the recorded shape (`consensus_angles`, `deliberation_count`).
- `packages/codex-learn/core/calibrate.lua` — where advocate calibration already closes on disposition; add per-angle.
- `packages/codex-learn/core/relearn.lua` — thread the per-angle calibration into `candidate_rubric` (next to `advocate_calibration`).
- `packages/codex-saga/core/consensus.lua` — consumer of any per-angle weights (if the aggregate rule changes).

### Related, smaller
Make the **success criteria explicit per package** in the docs. They're currently *clear but
implicit* — encoded in `disposition_label` + the AUC≥0.70 accept gate (`METHODOLOGY §6`,
`learning-model.md`). A short "success criteria" line per package (triage = pick win-rate / AUC;
saga = engagement → invite → merge; learn = accepted update) would make the tuning target legible.

---

## Other deferred items (flagged 2026-07-01, lower detail)

- **relearn writes to committed `data/`.** The empty-outcome guard (`relearn.lua`: accept requires
  `fold_counts.selection > 0`) stops the observed rubric gutting, but relearn still writes the
  rubric / styleguides / history to committed `data/` unconditionally. Default
  `FKST_LEARNING_ROOT` / `FKST_LEARNING_RUBRIC_PATH` to `.fkst/durable` and treat committed
  `data/area_rubric.json` as a read-only **seed** — closes the class of "a dry-run tick mutates
  committed source." (`codex-learn/core/io.lua`)
- **Incremental issue poll.** The mirror reconcile still does a full pull each refresh
  (~126 s / ~8k issues). Add a `?since=` / `sort=updated` incremental delta so the mirror is
  maintained cheaply between full reconciles. (`scripts/reconcile_issues.py`, `codex-triage`)
- **Stale docs.** `CLAUDE.md` + `docs/fkst-codex-harness-architecture.md` still describe the old
  5-department "stub" chain and omit `codex-learn`; refresh to the real 9-department, mirror-based,
  implemented state.
- **Windows portability (latent).** `mkdir -p` via `os.execute` / argv in `codex-learn/core/io.lua`
  and `codex-saga/core/outcomes_store.lua` is Unix-only; needs a portable substrate mkdir seam
  (or OS-aware fallback). Dirs normally pre-exist, so latent.
