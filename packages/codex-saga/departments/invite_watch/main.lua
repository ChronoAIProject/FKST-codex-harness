-- codex-saga/invite_watch: re-derive whether a maintainer invite has been recorded on
-- the UPSTREAM openai/codex candidate thread (invitation precondition, spec §10) -
-- maintainers reply upstream, not on our own tracker. Bridges engage and open_pr:
-- entered on codex_engaged and re-polled on the cron tick; raises codex_invited only
-- once an invite is recorded upstream. On the cron tick it also EXPIRES an engaged
-- candidate whose invite-wait window elapsed with no invite into a terminal IGNORED
-- outcome (#16, on_timeout="needs_invite"). Read-only on the foreign plane (gh reads
-- only); no foreign-plane write.
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

-- A single candidate just engaged: check its UPSTREAM candidate thread (source_ref) for
-- a recorded maintainer invite.
local function handle_engaged(event)
  local payload = event.payload or {}
  local dedup_key = payload.dedup_key
  -- Persist the diagnose-time verification fact durably NOW (whether or not an invite exists
  -- yet), so the cron RECOVERY path below can rehydrate the ACTUAL root_cause_verified for
  -- open_pr's fail-closed preflight instead of synthesizing it from a durable label (Codex
  -- review P1). Best-effort + local: reaching here means engage POSTED a substantiated
  -- dossier (root_cause_verified == true), so this is the honest fact, not an assumption.
  core.record_engaged_verification(dedup_key, {
    source_ref = payload.source_ref,
    root_cause_verified = payload.root_cause_verified,
    simulated = payload.simulated,
    demo_branch = payload.demo_branch,
    picked_score = payload.picked_score or payload.score,
    area_labels = payload.labels,
    type = payload.labels and core.classify_type(payload.labels) or nil,
  })
  if core.recorded_invite(dedup_key, payload.source_ref) then
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

-- Cron re-poll: scan open engaged control issues; for each, re-derive the invite fact
-- from the ORIGINAL upstream candidate thread (the source_ref recovered from the control
-- body's source marker, so the PR/CLA target never drifts to the tracker). The control
-- issue is trusted ONLY when bot-authored. A candidate that has since recorded a
-- maintainer invite raises codex_invited; a candidate whose invite-wait window has
-- elapsed with no invite is EXPIRED into a terminal IGNORED outcome (#16). Fail-closed
-- when the scan cannot be read (treated as "nothing invited yet").
local function handle_tick(_event)
  local bot = core.bot_login()
  local list = core.gh_read(core.gh_issue_list_argv(core.tracker_repo(), core.state_label("engaged"), "number,body,author,createdAt"))
  if type(list) ~= "table" then
    return nil
  end
  -- Resolve the maintainer allowlist ONCE for the whole scan (READ-only, best-effort;
  -- falls back to the curated list when the collaborators API is unavailable).
  local allowlist = core.resolve_maintainer_allowlist()
  for _, issue in ipairs(list) do
    if type(issue) == "table" and core.bot_authored(issue, bot) then
      local dedup_key = core.control_dedup_from_body(issue.body)
      local original_source_ref = core.control_source_ref_from_body(issue.body)
      if dedup_key ~= nil and original_source_ref ~= nil then
        if core.recorded_invite(dedup_key, original_source_ref, nil, allowlist) then
          -- Rehydrate the ACTUAL diagnose-time verification fact persisted at engage (never
          -- synthesize it from the durable `engaged` label - legacy/label-edited/pre-patch
          -- issues have no record). Only a candidate whose durable record shows
          -- root_cause_verified == true clears open_pr's fail-closed preflight; anything
          -- without a record carries nil and open_pr refuses (Codex review P1).
          local verification = core.load_engaged_verification(dedup_key) or {}
          core.record_transition(dedup_key, "invited", { control_issue = tostring(issue.number) })
          raise("codex_invited", {
            schema = "codex-saga.invited.v1",
            source_ref = original_source_ref,
            dedup_key = dedup_key,
            control_issue = tostring(issue.number),
            root_cause_verified = verification.root_cause_verified,
            demo_branch = verification.demo_branch,
            simulated = verification.simulated,
          })
        elseif core.invite_wait_expired(issue.createdAt) then
          -- #16: the invite-wait window elapsed with NO maintainer invite -> a terminal
          -- IGNORED outcome (a real negative learning signal in codex-learn's resolved
          -- set). READ-ONLY upstream + a LOCAL durable append; NO foreign write. Idempotent
          -- via the durable record (skips once a resolved terminal outcome already exists).
          core.record_invite_ignored(dedup_key, original_source_ref, tostring(issue.number))
        end
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
