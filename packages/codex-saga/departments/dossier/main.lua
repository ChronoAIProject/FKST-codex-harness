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
  if #engagement_exemplars > 0 then
    log.info("codex-saga/dossier engagement exemplars=" .. tostring(#engagement_exemplars))
  end

  -- Reference the REAL fix branch implement wrote (falling back to the deterministic
  -- name). Dry-run by default: logs the intended push and returns without any real
  -- push (gated on FKST_GITHUB_WRITE=1).
  local branch = payload.demo_branch or ("codex-saga/fix-" .. core.safe_segment(dedup_key))
  core.fork_push_intent(core.fork_local_path(), branch, dedup_key)

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
  }
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
  core.record_transition(dedup_key, "dossier", {})
  raise("codex_dossier", raised)
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "dossier",
})
