-- codex-learn durable-outcomes channel + §5 fold tests. codex-saga APPENDS one §5
-- record per line and the SAME dedup_key recurs (track's proposed/pending line, then
-- the final merged|closed line). The reader DEDUPS latest-wins, treats pending as
-- IN-FLIGHT, and folds each RESOLVED §5 record into ALL THREE banks (selection win/loss,
-- engagement reaction, pr ci/themes) so the rubric AND styleguides self-improve. Pure.
local core = require("core")
local t = fkst.test

local DK = "codex-triage:dup:openai/codex#1234"

-- Two §5 lines for the same dedup_key: a proposed/pending line, then the final merged.
local function proposed_then_merged()
  return {
    { dedup_key = DK, source_ref = { ref = "openai/codex#1234" }, picked_score = 70,
      area_labels = { "bug", "exec" }, type = "bug", exemplars_used = {},
      engagement_reaction = "reply", ci = "pending", review_comment_themes = {},
      disposition = "proposed", advocate_verdict = "pass", advocate_reason = "" },
    { dedup_key = DK, source_ref = { ref = "openai/codex#1234" }, picked_score = 70,
      area_labels = { "bug", "exec" }, type = "bug", exemplars_used = {},
      engagement_reaction = "positive", ci = "pass", review_comment_themes = {},
      disposition = "merged", advocate_verdict = "pass", advocate_reason = "" },
  }
end

return {
  -- latest-wins: the same dedup_key collapses to ONE record, the LAST (final) line.
  test_resolve_outcomes_latest_wins = function()
    local resolved = core.resolve_outcomes(proposed_then_merged())
    t.eq(#resolved, 1)
    t.eq(resolved[1].disposition, "merged") -- final supersedes pending
    t.eq(resolved[1].ci, "pass")
  end,

  test_is_resolved_outcome = function()
    t.eq(core.is_resolved_outcome({ disposition = "merged" }), true)
    t.eq(core.is_resolved_outcome({ disposition = "closed" }), true)
    t.eq(core.is_resolved_outcome({ disposition = "ignored" }), true)
    t.eq(core.is_resolved_outcome({ disposition = "proposed" }), false)
    t.eq(core.is_resolved_outcome({ ci = "pending" }), false)
  end,

  -- A resolved MERGED §5 outcome folds into ALL THREE banks: a selection WIN, an
  -- engagement record, and a pr_style record (deduped: the pending line is dropped).
  test_fold_merged_outcome_adds_all_three_corpora = function()
    local folded, counts = core.fold_outcomes(
      { selection = {}, engagement = {}, pr_style = {} },
      proposed_then_merged()
    )
    t.eq(counts.selection, 1)
    t.eq(counts.engagement, 1)
    t.eq(counts.pr_style, 1)
    t.eq(counts.in_flight, 0)
    t.eq(folded.selection[1].label, "win") -- merged => win
    t.eq(folded.engagement[1].outcome, "merged") -- positive reaction => success
    t.eq(folded.pr_style[1].merged, true)
  end,

  -- A closed outcome with no positive reaction folds as a selection LOSS.
  test_fold_closed_no_reaction_is_loss = function()
    local folded, counts = core.fold_outcomes({ selection = {}, engagement = {}, pr_style = {} }, {
      { dedup_key = "openai/codex#5", source_ref = { ref = "openai/codex#5" }, area_labels = { "bug" },
        type = "bug", engagement_reaction = "none", ci = "fail", review_comment_themes = { "scope" },
        disposition = "closed", advocate_verdict = "refuted" },
    })
    t.eq(counts.selection, 1)
    t.eq(folded.selection[1].label, "loss")
    t.eq(folded.engagement[1].outcome, "closed")
    t.eq(folded.pr_style[1].merged, false)
  end,

  -- a pending-ONLY dedup_key folds as in-flight: nothing enters any bank.
  test_fold_pending_only_is_in_flight = function()
    local folded, counts = core.fold_outcomes({ selection = {}, engagement = {}, pr_style = {} }, {
      { dedup_key = "openai/codex#9", area_labels = { "bug" }, type = "bug",
        disposition = "proposed", ci = "pending", advocate_verdict = "pass" },
    })
    t.eq(counts.selection, 0)
    t.eq(counts.engagement, 0)
    t.eq(counts.pr_style, 0)
    t.eq(counts.in_flight, 1)
    t.eq(#folded.selection, 0)
  end,

  -- calibrate scores the advocate against the FINAL record (merged => correct_pass).
  test_calibrate_latest_wins = function()
    local cal = core.calibrate_advocate(proposed_then_merged(), { prior_strictness = 45 })
    t.eq(cal.counts.evaluated, 1)
    t.eq(cal.counts.correct_pass, 1)
    t.eq(cal.counts.in_flight, 0)
  end,

  -- a pending-only record is excluded from calibration (in-flight, not evaluated).
  test_calibrate_pending_is_in_flight = function()
    local cal = core.calibrate_advocate({
      { dedup_key = "openai/codex#7", disposition = "proposed", ci = "pending",
        advocate_verdict = "pass", picked_score = 60 },
    }, { prior_strictness = 45 })
    t.eq(cal.counts.evaluated, 0)
    t.eq(cal.counts.in_flight, 1)
    t.eq(cal.recommended, "hold") -- no resolved error signal => no adjustment
  end,

  -- run_cycle threads the outcome-augmented engagement/pr corpora into the styleguide
  -- induction (NOT just the static bootstrap corpora): with EMPTY seed corpora, the lone
  -- merged outcome is the sole engagement + pr exemplar the styleguides re-induce over.
  test_run_cycle_styleguides_consume_augmented_corpora = function()
    local result = core.run_cycle({
      ts = 1,
      corpora = { selection = {}, engagement = {}, pr_style = {} },
      outcomes = {
        { dedup_key = "d1", source_ref = { ref = "openai/codex#1" }, picked_score = 70,
          area_labels = { "bug", "exec" }, type = "bug", exemplars_used = {},
          engagement_reaction = "positive", ci = "pass", review_comment_themes = { "flaky" },
          disposition = "merged", advocate_verdict = "pass" },
      },
    })
    -- the folded outcome reached all three banks
    t.eq(result.log_row.counts_in.folded.selection, 1)
    t.eq(result.log_row.counts_in.folded.engagement, 1)
    t.eq(result.log_row.counts_in.folded.pr_style, 1)
    -- styleguide induction consumed the augmented corpora
    t.eq(result.engagement.total, 1)
    t.eq(result.engagement.successful, 1)
    t.eq(result.engagement.rerank_summary.n, 1)
    t.eq(result.pr_style.merged_count, 1)
    t.eq(result.pr_style.rerank_summary.n, 1)
  end,
}
