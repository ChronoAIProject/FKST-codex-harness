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

  -- Compose the outward dossier body up front: both refuse-to-post gates read it, and the
  -- decision must be made BEFORE we mark the candidate engaged (see the terminal below).
  local body = core.engage_body(entity, payload)

  -- Two REFUSE-TO-POST integrity gates (spec §10 output contract):
  --   #22a/#2: refuse an UNSUBSTANTIATED dossier (unverified reproduction / root cause, no
  --            real validation, or no live pushed fork branch) - never boilerplate.
  --   #3:      refuse a NEAR-IDENTICAL duplicate of a recently-posted harness comment.
  -- A refusal is TERMINAL: if we will not post a public dossier we must NOT stamp `engaged`
  -- and must NOT raise codex_engaged. Otherwise invite_watch would poll an issue the bot
  -- never posted on, and a pre-existing maintainer comment there could satisfy the invite
  -- precondition and open an UNSOLICITED PR with no public engagement (integrated Codex
  -- review P1). The refusal lands on the durable funnel + the board as a `blocked` terminal
  -- (local, dry-run-safe; inert to codex-learn's fold). In the current dry-run posture (no
  -- real repro/pushed branch) this refuses every candidate here - the honest "no
  -- unsubstantiated posts" default until diagnose/implement wire real artifacts.
  local postable, refuse_reason = core.dossier_postable(payload)
  if postable then
    local diverse, dup_reason = core.diversity_ok(body, core.recent_engage_bodies())
    if not diverse then
      postable, refuse_reason = false, dup_reason
    end
  end
  if not postable then
    core.record_terminal_drop(dedup_key, {
      state = "blocked",
      reason = refuse_reason,
      source_ref = entity,
      picked_score = payload.score,
      area_labels = payload.labels,
      type = core.classify_type(payload.labels),
      root_cause = payload.root_cause,
    })
    core.record_transition(dedup_key, "blocked", {
      detail = "refused to post: " .. tostring(refuse_reason),
    })
    log.info("codex-saga/engage refuse-to-post: " .. tostring(refuse_reason)
      .. " - terminal; not engaging and not starting the invite path")
    return nil
  end

  -- Postable: establish ONE control issue per candidate on this harness repo's tracker and
  -- stamp the engage-time `engaged` label. Because we get here ONLY past the gates above,
  -- the `engaged` label now marks EXCLUSIVELY genuinely-posted (root-cause-verified)
  -- candidates - which is what makes the invite_watch recovery scan safe. Dry-run returns
  -- nil (no external write).
  local control_issue = core.ensure_engaged(dedup_key, entity, {
    score = payload.score,
    area_labels = payload.labels,
    type = core.classify_type(payload.labels),
  })
  -- Real-mode safety: never post a PUBLIC engagement we cannot track (the cap + invite/
  -- outcome scans key off the control issue), so fail closed BEFORE the upstream comment.
  if core.write_mode() == "real" and control_issue == nil then
    error("codex-saga/engage: could not establish the tracker control issue; refusing to post an untracked public engagement")
  end

  -- Outward dossier comment on the openai/codex candidate issue (dry-run unless
  -- FKST_GITHUB_WRITE=1). The body ALWAYS includes the AI-disclosure line; the marker gates
  -- the genuinely-once post. The intent is captured so the posted comment URL (gh stdout,
  -- real mode) lands on the board.
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

  -- A post genuinely happened only in real mode with a fresh gh result (not an idempotent
  -- skip). ONLY then does it count against the daily cap AND enter the diversity ring (so
  -- the next candidate is compared against it).
  local posted = core.write_mode() == "real"
    and comment_intent ~= nil
    and comment_intent.exit_code == 0
    and not comment_intent.skipped
    and not comment_intent.refused
  if posted then
    core.record_engagement()
    core.record_engage_body(body)
  end

  -- Mark the board engaged, linking the posted upstream comment (or the issue in dry-run).
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
  -- Thread the learning metadata (incl. root_cause_verified == true, guaranteed by the
  -- gate above) toward invite_watch/open_pr/track via the direct handoff.
  core.merge_learning(raised, payload)
  raise("codex_engaged", raised)
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "engage",
})
