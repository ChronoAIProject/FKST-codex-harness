-- codex-saga/dossier: build the contribution dossier (precedent story from the
-- worked-on corpus) and reference the real fix branch implement wrote on the fork
-- (owned plane). Local + read-only to the public; the fork push is dry-run unless
-- FKST_GITHUB_WRITE=1.
--
-- G-SAGA-HEAD: static spec table at file head (after requires, before any local fn).
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  -- Consumes implement's output so the demo branch references the REAL fix.
  consumes = { "codex_implemented" },
  produces = { "codex_dossier" },
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  local entity = payload.source_ref
  local dedup_key = payload.dedup_key

  -- Precedent story: re-read the worked-on corpus through the data pointer (never
  -- inlined into the payload) and select an analogous merged-PR fix to cite.
  local precedent = core.select_precedent(core.read_corpus(), payload.labels or {})
  if precedent ~= nil then
    log.info("codex-saga/dossier precedent #" .. tostring(precedent.number))
  end

  -- Retrieval-conditioned ENGAGEMENT learning (learning-model §4): retrieve the
  -- nearest SUCCESSFUL engagement threads via precedent.tfidf over corpus_engagement,
  -- conditioned on the induced styleguide rules. Carry only the exemplar REFS (never
  -- the threads) forward so engage composes the comment + track gets credit signal.
  local rules = core.read_engagement_styleguide()
  local engagement_exemplars = core.engagement_exemplar_refs(
    core.retrieve_engagement_exemplars(core.engagement_target(payload, rules)))
  -- #17: PREFER relearn's credit-weighted re-ranked exemplar bank order over the raw
  -- TF-IDF order (no-op until relearn has produced a styleguide with a bank section).
  engagement_exemplars = core.rerank_refs_by_bank(engagement_exemplars, core.read_engagement_exemplar_bank())
  if #engagement_exemplars > 0 then
    log.info("codex-saga/dossier engagement exemplars=" .. tostring(#engagement_exemplars))
  end

  -- Reference the REAL fix branch implement wrote (falling back to the deterministic
  -- name). Dry-run by default: logs the intended push and returns without any real
  -- push (gated on FKST_GITHUB_WRITE=1). Capture the intent so we can carry an HONEST
  -- `simulated` flag: the branch is a live tree/compare link downstream ONLY when the
  -- push actually landed (real mode, exit 0) - never in dry-run (#8).
  local branch = payload.demo_branch or ("codex-saga/fix-" .. core.safe_segment(dedup_key))
  local push_intent = core.fork_push_intent(core.fork_local_path(), branch, dedup_key)
  local branch_pushed = type(push_intent) == "table"
    and push_intent.mode == "real"
    and push_intent.exit_code == 0

  local raised = {
    schema = "codex-saga.dossier.v1",
    source_ref = entity,
    dedup_key = dedup_key,
    score = payload.score,
    labels = payload.labels,
    root_cause = payload.root_cause,
    demo_branch = branch,
    crate = payload.crate,
    -- the retrieved engagement exemplar refs condition the engage comment.
    engagement_exemplars = engagement_exemplars,
    -- Honest branch-liveness signal for engage (#8): the demo branch is a live link only
    -- when it was actually pushed. `simulated` is NOT a LEARNING_KEY, so set it here
    -- explicitly (merge_learning carries reproduced/root_cause_verified/validation/
    -- test_command). PM-NEEDS: add `simulated` to LEARNING_KEYS so it survives gate->engage.
    simulated = (payload.simulated == true) or (not branch_pushed),
  }
  -- Note: reproduced / root_cause_verified (Agent A) + validation / test_command (Agent E)
  -- arrive via core.merge_learning below (they are LEARNING_KEYS) and feed the #2 asserted-
  -- claim gate + the #7 validation line at engage.
  -- Thread the learning metadata (picked_score, advocate verdict) toward track, and
  -- fold the engagement exemplar refs into exemplars_used for credit assignment
  -- (alongside the implement PR-style exemplars).
  core.merge_learning(raised, payload)
  local exemplars_used = {}
  for _, ref in ipairs(payload.exemplars_used or {}) do
    table.insert(exemplars_used, ref)
  end
  for _, ref in ipairs(engagement_exemplars) do
    table.insert(exemplars_used, ref)
  end
  raised.exemplars_used = exemplars_used
  core.record_transition(dedup_key, "dossier", {
    detail = precedent ~= nil and ("precedent: #" .. tostring(precedent.number)
      .. " " .. tostring(precedent.title or "")) or nil,
    -- Honest branch line on the board: a live tree/compare LINK only when the push actually
    -- landed (real mode, exit 0); otherwise the bare name + a not-pushed note, mirroring the
    -- outward dossier's branch_is_live rendering so the tracker never claims a branch that
    -- was never pushed (integrated Codex review P2 / #8).
    summary = (branch_pushed
        and ("fix branch [" .. branch .. "](" .. core.branch_url(branch) .. ")"
          .. " · [compare vs upstream](" .. core.compare_url(branch) .. ")")
        or ("fix branch `" .. branch .. "` (prepared locally — not pushed)"))
      .. " · engagement exemplars: " .. tostring(#engagement_exemplars),
  })
  raise("codex_dossier", raised)
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "dossier",
})
