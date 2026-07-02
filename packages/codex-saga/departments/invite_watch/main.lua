-- codex-saga/invite_watch: re-derive whether a maintainer invite has been recorded
-- on the saga control issue (invitation precondition, spec §10). Bridges engage and
-- open_pr: entered on codex_engaged and re-polled on the cron tick; raises
-- codex_invited only once an invite is recorded. Read-only re-derivation; no
-- foreign-plane write.
--
-- G-SAGA-HEAD: static spec table at file head.
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "codex_engaged", "codex_invite_watch_tick" },
  produces = { "codex_invited" },
  stall_window = "30s",
}

local function done(_event)
  return false
end

-- A single candidate just engaged: check its control issue for a recorded invite.
local function handle_engaged(event)
  local payload = event.payload or {}
  local dedup_key = payload.dedup_key
  if core.recorded_invite(dedup_key, payload.control_issue) then
    local raised = {
      schema = "codex-saga.invited.v1",
      -- The ORIGINAL openai/codex candidate (carried on codex_engaged), never the
      -- tracker; plus the control-issue locator for the open_pr re-derivation.
      source_ref = payload.source_ref,
      dedup_key = dedup_key,
      control_issue = payload.control_issue,
    }
    -- Carry the learning metadata forward on the direct (engaged) handoff. The cron
    -- tick recovery path below re-derives from GitHub and has no such metadata.
    core.merge_learning(raised, payload)
    core.record_transition(dedup_key, "invited", { control_issue = payload.control_issue })
    raise("codex_invited", raised)
  end
end

-- Cron re-poll: scan open engaged control issues and raise codex_invited for any
-- that have since recorded a maintainer invite. The control issue is trusted ONLY
-- when bot-authored; the ORIGINAL candidate source_ref is re-derived from the
-- control body's source marker, so the PR/CLA target never drifts to the tracker.
-- Fail-closed when the scan cannot be read (treated as "nothing invited yet").
local function handle_tick(_event)
  local bot = core.bot_login()
  local list = core.gh_read(core.gh_issue_list_argv(core.tracker_repo(), core.state_label("engaged"), "number,body,author"))
  if type(list) ~= "table" then
    return nil
  end
  for _, issue in ipairs(list) do
    if type(issue) == "table" and core.bot_authored(issue, bot) then
      local dedup_key = core.control_dedup_from_body(issue.body)
      local original_source_ref = core.control_source_ref_from_body(issue.body)
      if dedup_key ~= nil and original_source_ref ~= nil
        and core.recorded_invite(dedup_key, issue.number) then
        core.record_transition(dedup_key, "invited", { control_issue = tostring(issue.number) })
        raise("codex_invited", {
          schema = "codex-saga.invited.v1",
          source_ref = original_source_ref,
          dedup_key = dedup_key,
          control_issue = tostring(issue.number),
        })
      end
    end
  end
end

local function act(event)
  local queue = tostring(event.queue or "")
  if queue:find("codex_invite_watch_tick", 1, true) ~= nil then
    return handle_tick(event)
  end
  if queue:find("codex_engaged", 1, true) ~= nil then
    return handle_engaged(event)
  end
  -- Fail-closed: a consumed queue must be routed, never silently skipped.
  error("codex-saga/invite_watch: unsupported consumed queue `" .. queue .. "`")
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "invite_watch",
})
