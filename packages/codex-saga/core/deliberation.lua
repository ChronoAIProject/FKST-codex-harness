-- core.deliberation: durable capture of the gate's DELIBERATION signals so the
-- "N discussions / advocate refused M" funnel is retrievable from the durable
-- outcomes channel EVEN IN DRY-RUN (learning-model §7).
--
-- Why here, not on a GitHub issue: the gate is write_class=false and creates NO control
-- issue (that is born at engage). A REFUSED candidate never reaches engage, so its
-- deliberation has no issue to live on. The outcomes JSONL append is UNCONDITIONAL (never
-- gated by FKST_GITHUB_WRITE), so a refusal recorded here is the dry-run source of truth.
--
-- Learning safety: refusal records carry a disposition OUTSIDE the resolved set
-- {merged,closed,ignored}, so codex-learn's fold + calibration SKIP them
-- (relearn.is_resolved_outcome). They are retrievable, but never (mis)counted as a
-- win/loss learning signal - a refused pick has no real-world disposition to score.
local S = {}

-- Gate drop reason -> the durable disposition recorded for it. Every value is OUTSIDE
-- codex-learn's resolved set, so all are inert to the learning fold (see above).
local REFUSAL_DISPOSITIONS = {
  security = "refused_security",
  invite_policy = "refused_policy",
  disclosure = "refused_policy",
  volume_cap = "refused_volume_cap",
  consensus = "refused_consensus",
}

function S.install(M)
  M.refusal_dispositions = REFUSAL_DISPOSITIONS

  -- zip_angles(angle_results[, dissent]) -> the per-angle verdict MAP keyed by angle
  -- name (M.consensus_angles + "devils-advocate"), so the align/blast/dissent verdicts
  -- survive as a small scalar map instead of a positional array that loses meaning.
  function M.zip_angles(angle_results, dissent)
    local map = {}
    for i, name in ipairs(M.consensus_angles or {}) do
      map[name] = (type(angle_results) == "table" and angle_results[i]) or "unknown"
    end
    if type(dissent) == "table" then
      map["devils-advocate"] = (dissent.blocking == true) and "block" or "dissent"
    end
    return map
  end

  -- deliberation_count(angle_results[, dissent]) -> the number of independent judgments
  -- the gate weighed (consensus angles + the dissent angle).
  function M.deliberation_count(angle_results, dissent)
    local n = 0
    if type(angle_results) == "table" then
      n = #angle_results
    end
    if dissent ~= nil then
      n = n + 1
    end
    return n
  end

  -- record_deliberation(dedup_key, delib[, opts]) -> append ONE durable §5-shaped refusal
  -- record to the outcomes channel (UNCONDITIONAL; dry-run-safe; NO foreign write). delib:
  --   { reason, source_ref, picked_score, area_labels, type, advocate_verdict,
  --     advocate_reason, consensus_angles, deliberation_count }
  -- `reason` selects the disposition (all OUTSIDE the resolved set), so the record is
  -- retrievable yet inert to codex-learn. opts.path overrides the outcomes path (tests).
  function M.record_deliberation(dedup_key, delib, opts)
    delib = delib or {}
    local outcome = {
      source_ref = delib.source_ref,
      picked_score = delib.picked_score,
      area_labels = delib.area_labels,
      type = delib.type,
      engagement_reaction = "refused",
      disposition = REFUSAL_DISPOSITIONS[delib.reason] or "refused_at_gate",
      advocate_verdict = delib.advocate_verdict or "refuted",
      advocate_reason = delib.advocate_reason,
      consensus_angles = delib.consensus_angles,
      deliberation_count = delib.deliberation_count,
    }
    -- BEST-EFFORT: the gate is write_class=false; its durable truth is the drop decision
    -- + log. This stats side-channel must NEVER convert a safety REFUSAL into a pipeline
    -- failure, so a durable-channel hiccup is swallowed (returns nil). The TERMINAL track
    -- record stays strict/fail-loud via append_outcome; only this non-terminal line is lenient.
    local ok, path = pcall(M.append_outcome, dedup_key, outcome, opts)
    if ok then
      return path
    end
    return nil
  end

  -- record_cleared(dedup_key, delib[, opts]) -> append ONE durable §5 record for a gate
  -- PASS, symmetric with record_deliberation's refusal. Without this, a cleared candidate
  -- has no durable trace in dry-run (its deliberation only threads forward to `track`, which
  -- is unreachable without a real invite/PR), so the funnel's "cleared gate" is invisible.
  -- disposition="cleared" is OUTSIDE codex-learn's resolved set {merged,closed,ignored}, so
  -- it is retrievable yet inert to the learning fold. UNCONDITIONAL + local (NO foreign
  -- write); BEST-EFFORT (a durable hiccup must never fail the pass path). delib:
  --   { source_ref, picked_score, area_labels, type, advocate_verdict, advocate_reason,
  --     consensus_angles, deliberation_count, state }
  function M.record_cleared(dedup_key, delib, opts)
    delib = delib or {}
    local outcome = {
      source_ref = delib.source_ref,
      picked_score = delib.picked_score,
      area_labels = delib.area_labels,
      type = delib.type,
      engagement_reaction = "none",
      disposition = "cleared",
      state = delib.state or "engage",
      advocate_verdict = delib.advocate_verdict or "pass",
      advocate_reason = delib.advocate_reason,
      consensus_angles = delib.consensus_angles,
      deliberation_count = delib.deliberation_count,
    }
    local ok, path = pcall(M.append_outcome, dedup_key, outcome, opts)
    if ok then
      return path
    end
    return nil
  end

  -- deliberation_stats([opts]) -> the funnel counts derived from the durable channel
  -- (latest-wins by dedup_key, the SAME view codex-learn takes). opts.path overrides the
  -- outcomes path (tests). Returns:
  --   deliberated        = reached the consensus/advocate panel (refused_consensus + cleared)
  --   refused            = any gate drop (disposition matching ^refused)
  --   refused_by_advocate= dropped specifically by consensus/advocate (the hero stat)
  --   cleared            = passed the gate (non-refused disposition)
  function M.deliberation_stats(opts)
    local records = M.latest_outcome_by_dedup(M.read_outcomes(opts))
    local stats = { deliberated = 0, refused = 0, refused_by_advocate = 0, cleared = 0 }
    for _, oc in pairs(records) do
      local disposition = tostring(oc.disposition or "")
      if disposition:find("^refused") ~= nil then
        stats.refused = stats.refused + 1
        if disposition == "refused_consensus" then
          stats.refused_by_advocate = stats.refused_by_advocate + 1
          stats.deliberated = stats.deliberated + 1
        end
      else
        stats.cleared = stats.cleared + 1
        stats.deliberated = stats.deliberated + 1
      end
    end
    return stats
  end
end

return S
