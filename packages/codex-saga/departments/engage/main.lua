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

  -- Saga state model: ONE control issue per candidate on this harness repo's tracker.
  -- It was likely ADOPTED at diagnose for high-score candidates; ensure_engaged is the
  -- idempotent fallback that creates it for the rest, RESOLVES its number reliably (from
  -- the create output or by marker), and stamps the engage-time `engaged` label the volume
  -- cap + invite/outcome scans key off. Dry-run returns nil with no external write.
  local control_issue = core.ensure_engaged(dedup_key, entity, {
    score = payload.score,
    area_labels = payload.labels,
    type = core.classify_type(payload.labels),
  })
  -- Real-mode safety: never post a PUBLIC engagement we cannot track. If the control
  -- issue could not be established (so the daily cap + invite/outcome scans would miss it),
  -- fail closed BEFORE the upstream comment.
  if core.write_mode() == "real" and control_issue == nil then
    error("codex-saga/engage: could not establish the tracker control issue; refusing to post an untracked public engagement")
  end

  if core.upstream_engagement_held() then
    local until_ts = core.upstream_engagement_hold_until()
    log.info("codex-saga/engage: upstream engagement hold active until "
      .. tostring(until_ts) .. "; not posting to " .. tostring(candidate.repo))
    core.record_transition(dedup_key, "cleared", {
      control_issue = control_issue,
      summary = "upstream engagement hold active until " .. tostring(until_ts)
        .. "; fix/dossier work may continue, but no comment is posted to "
        .. tostring(candidate.repo) .. " during the hold.",
    })
    return nil
  end

  -- Outward dossier comment on the openai/codex candidate issue. The body ALWAYS
  -- includes the AI-disclosure line; the marker gates the genuinely-once post. The
  -- intent is captured so the posted comment URL (gh stdout, real mode) lands on the
  -- board.
  local body = core.engage_body(entity, payload)
  local comment_intent = core.egress_write({
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

  -- Mark the board: engaged, linking the posted upstream comment (or the upstream
  -- issue when the comment URL is unavailable, e.g. idempotent skip).
  local comment_url = core.url_from_intent(comment_intent) or core.issue_url(entity)
  core.record_transition(dedup_key, "engaged", {
    control_issue = control_issue,
    detail = comment_url ~= nil and ("dossier comment: " .. comment_url) or nil,
  })

  local raised = {
    schema = "codex-saga.engaged.v1",
    source_ref = entity,
    dedup_key = dedup_key,
    -- Carry the control-issue locator so invite_watch/open_pr/track get a reliable direct
    -- handoff (they can still re-derive by marker, but this avoids a lookup + the nil case).
    control_issue = control_issue and tostring(control_issue) or nil,
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
