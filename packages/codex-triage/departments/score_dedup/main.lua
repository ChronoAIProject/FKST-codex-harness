-- codex-triage/score_dedup: consume the poll tick, read openai/codex open issues,
-- score (METHODOLOGY §5) every issue then dedup (§7) the ATTEMPT set by cluster,
-- raising codex_candidate with a SMALL payload once per cluster-key.
--
-- G-SAGA-HEAD: the static spec table sits at file head (after requires, before any
-- local function) so the engine graph contract stays greppable.
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "codex_issue_poll_tick" },
  produces = { "codex_candidate" },
  stall_window = "30s",
}

-- done(event) is cheap + side-effect-free. Triage is a stateless adapter (each
-- tick re-derives from the live source), so there is no terminal fact to probe.
local function done(_event)
  return false
end

-- act consumes the cron tick and runs the METHODOLOGY §8 funnel IN ORDER:
-- score+bin EVERY polled issue -> take the ATTEMPT set -> THEN dedup by cluster,
-- raising the FROZEN codex_candidate contract exactly once per cluster-key. A
-- cluster with an ATTEMPT member is never dropped just because its most-reacted
-- representative scored below ATTEMPT (core.attempt_candidates owns that order).
--
-- Injectable seam: in production the issue list + cluster corpus + target are read
-- read-only from openai/codex (gh) and data/ (file). Tests inject them through the
-- event payload (issues / clusters / target) so the suite needs NO network or IO.
-- The production poll path is therefore never hit under `run.sh test`.
local function act(event)
  local payload = (event and event.payload) or {}

  local repo = payload.target or core.contrib_target()
  local issues = payload.issues or core.poll_open_issues(repo)
  local clusters = payload.clusters
  if clusters == nil then
    clusters = core.load_clusters()
  end
  local index = core.cluster_index(clusters)

  -- Small payloads only: {source_ref, dedup_key, schema, score}. NEVER the body -
  -- the consumer re-fetches via source_ref.
  for _, candidate in ipairs(core.attempt_candidates(issues, index, repo)) do
    raise("codex_candidate", candidate)
  end

  return nil
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "score_dedup",
})
