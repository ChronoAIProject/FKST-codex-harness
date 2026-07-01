-- codex-saga/engage: the first outward action. Posts the dossier as a gh comment on
-- the openai/codex candidate issue (foreign plane) AND creates/tracks the saga
-- control issue on this harness repo's tracker. Dry-run unless FKST_GITHUB_WRITE=1;
-- the outward post MUST carry the AI-disclosure and is gated on a bot-authored
-- marker (once()/cache_* are only in-runtime debounce).
--
-- G-SAGA-HEAD: static spec table at file head (after requires, before any local fn).
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "codex_cleared" },
  produces = { "codex_engaged" },
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  local entity = payload.source_ref
  local dedup_key = payload.dedup_key
  local candidate = core.parse_entity_ref(entity)
  if candidate == nil then
    error("codex-saga/engage: candidate source_ref is not a recognizable issue pointer")
  end

  -- Saga state model: create/track ONE control issue per candidate on this harness
  -- repo's tracker, with program-produced labels + state markers. Dry-run logs the
  -- intended create/label/marker ops.
  core.egress_write({
    op = "control-issue-create",
    repo = core.tracker_repo(),
    dedup_key = dedup_key,
    title = core.control_title(dedup_key),
    labels = { core.state_label("engaged") },
    -- Persist the ORIGINAL candidate source_ref as a tiny pointer in the control
    -- body (via the source marker) so the invite path never drifts the target.
    body = core.control_body(dedup_key, "engaged", entity),
    marker = core.control_marker(dedup_key),
    argv_builder = function(path)
      return core.gh_issue_create_argv(core.tracker_repo(), core.control_title(dedup_key), path, { core.state_label("engaged") })
    end,
    marker_present = function()
      -- Trust the control marker ONLY when the control issue is bot-authored.
      local bot = core.bot_login()
      local list = core.gh_read(core.gh_issue_list_argv(core.tracker_repo(), core.state_label("engaged"), "number,body,author"))
      if type(list) ~= "table" then
        return false
      end
      local marker = core.control_marker(dedup_key)
      for _, issue in ipairs(list) do
        if core.trusted_marker(issue, marker, bot) then
          return true
        end
      end
      return false
    end,
  })

  -- Outward dossier comment on the openai/codex candidate issue. The body ALWAYS
  -- includes the AI-disclosure line; the marker gates the genuinely-once post.
  local body = core.engage_body(entity, payload)
  core.egress_write({
    op = "engage-comment",
    repo = candidate.repo,
    dedup_key = dedup_key,
    body = body,
    marker = core.engage_marker(dedup_key),
    argv_builder = function(path)
      return core.gh_issue_comment_argv(candidate.repo, candidate.number, path)
    end,
    marker_present = function()
      -- Trust the engage marker ONLY on a bot-authored comment.
      local bot = core.bot_login()
      local view = core.gh_read(core.gh_issue_view_argv(candidate.repo, candidate.number, "comments"))
      if type(view) ~= "table" then
        return false
      end
      local marker = core.engage_marker(dedup_key)
      for _, comment in ipairs(view.comments or {}) do
        if core.trusted_marker(comment, marker, bot) then
          return true
        end
      end
      return false
    end,
  })

  -- Count the public engagement against the daily cap (real posture only).
  if core.write_mode() == "real" then
    core.record_engagement()
  end

  local raised = {
    schema = "codex-saga.engaged.v1",
    source_ref = entity,
    dedup_key = dedup_key,
  }
  -- Thread the learning metadata (exemplars_used, picked_score, advocate verdict)
  -- toward track via the direct (non-recovery) handoff.
  core.merge_learning(raised, payload)
  raise("codex_engaged", raised)
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "engage",
})
