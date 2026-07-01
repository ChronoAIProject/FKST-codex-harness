-- core.relearn: the re-derivation ORCHESTRATION (docs/learning-model.md §3/§6).
--
-- run_cycle() is PURE given already-loaded inputs: it folds durable outcomes into the
-- working corpora, re-fits the selection weights + evaluates the §6 gate, re-induces
-- both styleguides, re-ranks the exemplar banks, calibrates the advocate, and builds
-- the candidate rubric + the relearn_log row + the styleguide markdown. It performs
-- NO IO; core.io reads the inputs and commits the outputs. Keeping the cycle pure is
-- what lets tests run a full re-derivation against inline fixtures with no disk/net.
local S = {}

local function copy_array(arr)
  local out = {}
  for i, v in ipairs(arr or {}) do
    out[i] = v
  end
  return out
end

-- The §5 win/loss signal from OUR pick (durable-outcomes fold contract): a merged
-- disposition OR a positive maintainer reaction (invited/positive) is a WIN; a
-- closed/ignored disposition with no positive reaction (none/reply) is a LOSS. Only
-- called for RESOLVED outcomes, so it always returns "win" or "loss".
local function disposition_label(oc)
  if oc.disposition == "merged" or oc.engagement_reaction == "invited" or oc.engagement_reaction == "positive" then
    return "win"
  end
  return "loss"
end

-- Our comment's reaction -> the engagement-corpus outcome used for exemplar reranking.
local function engagement_outcome(oc)
  if oc.disposition == "merged" or oc.engagement_reaction == "invited" or oc.engagement_reaction == "positive" then
    return "merged"
  end
  return "closed"
end

-- A small weight standing in for "maintainer_reactions" so the engagement rerank's
-- base score reflects how positively our comment landed.
local function reaction_weight(oc)
  if oc.engagement_reaction == "invited" then
    return 2
  end
  if oc.engagement_reaction == "positive" then
    return 1
  end
  return 0
end

-- Ensure the issue's `type` (bug|regression|enhancement) is present among the area
-- labels so the rubric scorer's type bonus fires for our folded outcome even if the
-- recorded area_labels omitted it. ("other" is not a scorer label, so it is ignored.)
local function area_labels_with_type(area_labels, kind)
  local out = {}
  for _, l in ipairs(area_labels or {}) do
    out[#out + 1] = l
  end
  if type(kind) == "string" and kind ~= "other" and kind ~= "" then
    local lower = kind:lower()
    for _, l in ipairs(out) do
      if tostring(l):lower() == lower then
        return out -- already present
      end
    end
    out[#out + 1] = kind
  end
  return out
end

function S.install(M)
  -- resolve_outcomes(outcomes) -> the deduped outcome set (durable-outcomes channel
  -- contract). codex-saga APPENDS one §5 record per line and the SAME dedup_key may
  -- appear MULTIPLE times (track's proposed/pending line, then outcome_watch's final
  -- merged|closed line). We keep the LAST occurrence per dedup_key so the final outcome
  -- SUPERSEDES the earlier proposed/pending record. Records without a dedup_key are kept
  -- individually (each gets a unique synthetic key, never collapsed). First-appearance
  -- order is preserved for deterministic downstream output.
  function M.resolve_outcomes(outcomes)
    local order, by_key = {}, {}
    local synthetic = 0
    for _, oc in ipairs(outcomes or {}) do
      local key = oc.dedup_key
      if type(key) ~= "string" or key == "" then
        synthetic = synthetic + 1
        key = "__nodedup__/" .. tostring(synthetic)
      end
      if by_key[key] == nil then
        order[#order + 1] = key
      end
      by_key[key] = oc -- LAST occurrence wins
    end
    local out = {}
    for _, key in ipairs(order) do
      out[#out + 1] = by_key[key]
    end
    return out
  end

  -- is_resolved_outcome(oc) -> true only when the attempt has REACHED a terminal
  -- disposition (merged|closed|ignored). A proposed/pending (or dispositionless) record
  -- is IN-FLIGHT: it is excluded from folding + calibration so a not-yet-final attempt
  -- is never (mis)counted as a win/loss learning signal.
  function M.is_resolved_outcome(oc)
    local d = type(oc) == "table" and oc.disposition or nil
    return d == "merged" or d == "closed" or d == "ignored"
  end

  -- fold_outcomes(corpora, outcomes) -> augmented corpora (new arrays) + fold counts.
  --
  -- Consumes the §5 durable-outcomes shape codex-saga writes (one JSONL line per
  -- attempt): { source_ref, dedup_key, picked_score, area_labels, type, exemplars_used,
  -- engagement_reaction, ci, review_comment_themes, disposition, advocate_verdict,
  -- advocate_reason }. Outcomes are first resolved (latest-wins by dedup_key); only
  -- RESOLVED ones (disposition merged|closed|ignored) fold in -- pending/proposed are
  -- in-flight and contribute nothing. Each resolved outcome contributes to ALL THREE
  -- banks so the rubric re-fit AND both styleguides self-improve from our attempts:
  --   selection  : our real win/loss signal (drives the weight re-fit)
  --   engagement : our comment's reaction -> outcome (drives engagement rerank)
  --   pr_style   : our PR's ci / review themes / disposition (drives pr rerank)
  -- The seed corpora are copied, never mutated (read-only seeds, §6).
  function M.fold_outcomes(corpora, outcomes)
    corpora = corpora or {}
    local selection = copy_array(corpora.selection)
    local engagement = copy_array(corpora.engagement)
    local pr_style = copy_array(corpora.pr_style)
    local counts = { selection = 0, engagement = 0, pr_style = 0, in_flight = 0 }

    for _, oc in ipairs(M.resolve_outcomes(outcomes)) do
      if not M.is_resolved_outcome(oc) then
        counts.in_flight = counts.in_flight + 1
      else
        selection[#selection + 1] = {
          source_ref = oc.source_ref,
          dedup_key = oc.dedup_key,
          label = disposition_label(oc),
          area_labels = area_labels_with_type(oc.area_labels, oc.type),
          type = oc.type,
          win_quality = "our_outcome",
        }
        counts.selection = counts.selection + 1

        engagement[#engagement + 1] = {
          source_ref = oc.source_ref,
          outcome = engagement_outcome(oc),
          reaction = oc.engagement_reaction,
          thread_moves = {}, -- we record the reaction, not the contributors' full thread
          maintainer_reactions = reaction_weight(oc),
        }
        counts.engagement = counts.engagement + 1

        pr_style[#pr_style + 1] = {
          source_ref = oc.source_ref,
          merged = (oc.disposition == "merged"),
          ci = oc.ci,
          review_comment_themes = oc.review_comment_themes or {},
          disposition = oc.disposition,
          touched_paths = {}, -- the diff geometry is not carried in the §5 record
        }
        counts.pr_style = counts.pr_style + 1
      end
    end

    return { selection = selection, engagement = engagement, pr_style = pr_style }, counts
  end

  -- candidate_rubric(prior, selection_model, calibration, ts) -> the rubric table to
  -- snapshot (always) and to publish to data/area_rubric.json (only on accept). The
  -- prior's fields (areas/trust_ladder/...) are preserved; we add the fitted block.
  function M.candidate_rubric(prior, selection_model, calibration, ts)
    local out = {}
    if type(prior) == "table" then
      for k, v in pairs(prior) do
        out[k] = v
      end
    end
    out.selection_model = {
      fitted_at = ts,
      accepted = selection_model.accepted,
      auc = selection_model.auc or M.json_null,
      monotonic = selection_model.monotonic,
      weights = selection_model.weights,
      bins = selection_model.bins,
      counts = selection_model.counts,
      gate = selection_model.gate,
      feature_space = selection_model.feature_space,
      method = selection_model.method,
    }
    out.advocate_calibration = {
      calibrated_at = ts,
      strictness = calibration.new_strictness,
      recommended = calibration.recommended,
      valid_objection_themes = calibration.valid_objection_themes,
    }
    return out
  end

  -- run_cycle(input) -> the full cycle result (pure). input:
  --   ts                integer timestamp (engine event ts / host time, NOT os.time)
  --   corpora           { selection=[], engagement=[], pr_style=[] }
  --   outcomes          durable outcome records (folded in + drive calibration)
  --   prior_rubric      the currently-accepted area_rubric.json (preserved on reject)
  --   prior_strictness  the advocate's current strictness threshold
  function M.run_cycle(input)
    input = input or {}
    local ts = input.ts or 0
    local outcomes = input.outcomes or {}
    local resolved_outcomes = M.resolve_outcomes(outcomes)

    local augmented, fold_counts = M.fold_outcomes(input.corpora or {}, outcomes)

    -- The re-fit uses the AUGMENTED selection corpus (our wins/losses folded in), and
    -- the styleguide induction + exemplar rerank use the AUGMENTED engagement/pr corpora
    -- PLUS the resolved outcomes (for §5 exemplars_used credit) -- so both the rubric
    -- AND the styleguides self-improve from our outcomes, not just the bootstrap corpora.
    local selection_model = M.evaluate(augmented.selection)
    local engagement = M.induce_engagement(augmented.engagement, resolved_outcomes)
    local pr_style = M.induce_pr_style(augmented.pr_style, resolved_outcomes)
    local calibration = M.calibrate_advocate(outcomes, { prior_strictness = input.prior_strictness })

    local accepted = selection_model.accepted
    local candidate_rubric = M.candidate_rubric(input.prior_rubric, selection_model, calibration, ts)

    local log_row = {
      ts = ts,
      status = accepted and "accepted" or "rejected",
      accepted = accepted,
      counts_in = {
        selection = #augmented.selection,
        engagement = #augmented.engagement,
        pr_style = #augmented.pr_style,
        outcomes = #outcomes, -- raw appended lines read
        outcomes_resolved = #resolved_outcomes, -- after latest-wins dedup by dedup_key
        folded = fold_counts, -- {selection, engagement, pr_style, in_flight}
      },
      auc = selection_model.auc or M.json_null,
      monotonic = selection_model.monotonic,
      candidate_metrics = {
        auc = selection_model.auc or M.json_null,
        monotonic = selection_model.monotonic,
        accepted = accepted,
        bins = selection_model.bins,
        weights = selection_model.weights,
        counts = selection_model.counts,
        gate = selection_model.gate,
        feature_space = selection_model.feature_space,
        method = selection_model.method,
      },
      exemplar_rerank_summary = {
        engagement = engagement.rerank_summary,
        pr_style = pr_style.rerank_summary,
      },
      advocate_calibration_delta = calibration,
    }

    return {
      ts = ts,
      accepted = accepted,
      selection_model = selection_model,
      engagement = engagement,
      pr_style = pr_style,
      calibration = calibration,
      candidate_rubric = candidate_rubric,
      log_row = log_row,
      styleguides = {
        engagement_md = M.render_engagement_md(engagement),
        pr_md = M.render_pr_md(pr_style),
      },
    }
  end
end

return S
