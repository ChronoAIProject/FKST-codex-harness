-- codex-saga/outcome_watch: the closed PR-outcome feedback loop (learning-model
-- §5/§6). Consumes the cron tick and, for each proposed/tracked candidate, RE-DERIVES
-- READ-ONLY from GitHub the closing-PR CI status + review_comment_themes + final
-- disposition (merged|closed) + engagement_reaction, then UPDATES the durable outcome
-- record (the same §5 outcome track wrote) with the real facts so codex-learn/relearn
-- has a genuine signal. READ-ONLY on the foreign plane (gh reads only); the durable
-- upsert reuses core.egress (dry-run by default). NO foreign write happens here.
--
-- G-SAGA-HEAD: static spec table at file head (after requires, before any local fn).
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "codex_outcome_watch_tick" },
  produces = { "codex_outcome_updated" },
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function act(_event)
  -- Broadened reconcile (#12): scan the tracker for ALL marker-bearing control issues by
  -- the stable `candidate` label across --state all (open/closed, regardless of the
  -- current phase label), so engagement history relabeled/closed through resets is not
  -- lost. Read-only re-derivation; fail-closed (an unreadable scan yields nothing). Only
  -- candidates with a real closing PR upstream produce an outcome record (dry-run has
  -- none), so this recovers exactly the proposed candidates that reached upstream.
  local candidates = core.proposed_candidates()
  local recovered = 0
  for _, candidate in ipairs(candidates) do
    local derived = core.rederive_candidate_outcome(candidate)
    if derived ~= nil then
      recovered = recovered + 1
      -- APPEND the re-derived FINAL §5 record (disposition=merged|closed, real ci,
      -- review themes, engagement reaction) to the durable outcomes JSONL -
      -- UNCONDITIONAL (NOT gated by the GitHub outcome_marker). Latest-wins by
      -- dedup_key, so this final record supersedes track's initial pending one. This
      -- is the closed feedback loop codex-learn reads. NO foreign write happens here:
      -- the re-derivation is gh-READ-only and the append is a local durable write.
      -- Inherit area_labels + type (+ picked_score/exemplars/advocate) from track's
      -- prior durable record so the FINAL line carries them too.
      local prior = core.latest_outcome_by_dedup(core.read_outcomes())[candidate.dedup_key]
      local outcome = core.merge_outcome_facts(
        core.build_outcome(core.prior_outcome_fields(prior, candidate.source_ref)), derived)
      core.append_outcome(candidate.dedup_key, outcome)
      core.record_transition(candidate.dedup_key,
        (derived.disposition == "merged") and "merged" or "closed",
        { control_issue = candidate.control_issue })

      raise("codex_outcome_updated", {
        schema = "codex-saga.outcome_updated.v1",
        source_ref = candidate.source_ref,
        dedup_key = candidate.dedup_key,
        ci = derived.ci,
        disposition = derived.disposition,
        engagement_reaction = derived.engagement_reaction,
        review_comment_themes = derived.review_comment_themes,
      })
    end
  end
  -- Reconcile summary (describes EXACTLY what was recovered: candidates scanned by the
  -- broadened marker query, and how many had a real closing PR whose outcome was refreshed).
  log.info(string.format("codex-saga/outcome_watch reconcile: scanned=%d recovered=%d marker-bearing control issues",
    #candidates, recovered))
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "outcome_watch",
})
