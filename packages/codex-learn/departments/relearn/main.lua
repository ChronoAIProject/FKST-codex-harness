-- codex-learn/relearn: consume the scheduled tick and run ONE full re-derivation.
--
-- This department does ALL the write-class work (docs/learning-model.md §3/§6):
--   a. fold the durable `outcomes` into the normalized corpora;
--   b. RE-FIT the selection weights over corpus_selection in the rubric scorer's
--      feature space, evaluate the §6 gate (AUC>=0.70 AND monotonic per-bin win-rate),
--      ACCEPT only if it clears; on REJECT keep the prior accepted area_rubric.json;
--   c. re-induce the engagement + PR styleguides and re-rank the exemplar banks;
--   d. ALWAYS snapshot data/learning/rubric_history/area_rubric.<ts>.json AND append
--      a row to data/learning/relearn_log.jsonl (INCLUDING on rejection); on accept
--      also publish data/area_rubric.json. relearn is the ONLY writer of these banks.
--
-- G-SAGA-HEAD: the static spec sits at file head (after requires, before any local fn).
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "codex_relearn_tick" },
  -- Terminal sink: the re-derivation writes the committed banks to disk; it raises no
  -- downstream event. Departments apply the banks at the next decision (retrieval).
  stall_window = "30s",
}

-- done(event) is cheap + side-effect-free. The cron tick re-derives from the corpora
-- each cycle; there is no terminal fact to probe, so each delivered tick runs once.
local function done(_event)
  return false
end

-- act runs exactly ONE re-derivation per tick (idempotency: a redelivery of the SAME
-- tick within a runtime is debounced by a cache marker keyed on the learning-root + ts).
--
-- Injectable seam (mirrors codex-triage/score_dedup): in production all inputs are read
-- read-only by path (data/ + the durable outcomes) and outputs go to data/. Tests inject
-- corpora/outcomes/prior_rubric inline AND point learning_root/rubric_path at a TEMP dir,
-- so the suite drives a full cycle with NO network/IO against the real committed data/.
local function act(event)
  local payload = (event and event.payload) or {}

  local ts = core.event_ts(event)
  if ts == nil then
    error("codex-learn/relearn: no engine-provided time (event.ts / now()) available")
  end

  local config = core.relearn_config(payload)

  -- Idempotency: one re-derivation per tick (best-effort within-runtime debounce keyed
  -- on the learning-root + ts so distinct test temp-roots never collide).
  local guard_key = "codex-learn/relearn/tick/" .. core.safe_key_segment(config.learning_root) .. "/" .. tostring(ts)
  if type(cache_get) == "function" and cache_get(guard_key) ~= nil then
    log.info("codex-learn/relearn: skip-idempotent tick already re-derived ts=" .. tostring(ts))
    return nil
  end

  local inputs = core.read_inputs(config, payload)
  local result = core.run_cycle({
    ts = ts,
    corpora = inputs.corpora,
    outcomes = inputs.outcomes,
    prior_rubric = inputs.prior_rubric,
    prior_strictness = inputs.prior_strictness,
  })

  local written = core.commit(result, config)

  if type(cache_set) == "function" then
    cache_set(guard_key, "1")
  end

  log.info(t("codex-learn.relearn.cycle", {
    ts = tostring(ts),
    status = result.accepted and "accepted" or "rejected",
    auc = tostring(result.selection_model.auc),
    monotonic = tostring(result.selection_model.monotonic),
  }))
  log.info(string.format(
    "codex-learn/relearn: snapshot=%s log=%s rubric_published=%s",
    tostring(written.snapshot_path), tostring(written.relearn_log_path), tostring(written.rubric_written)
  ))

  return nil
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "relearn",
})
