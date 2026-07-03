-- codex-saga/open_pr: open the fork->upstream PR, but ONLY after a recorded
-- maintainer invitation (HARD invitation precondition, spec §10 gate3). The invite
-- is RE-DERIVED read-only from the control issue, never trusted from the payload.
-- Dry-run unless FKST_GITHUB_WRITE=1; the PR + CLA comment are marker-gated.
--
-- G-SAGA-HEAD: static spec table at file head (after requires, before any local fn).
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "codex_invited" },
  produces = { "codex_proposed" },
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  local entity = payload.source_ref
  local dedup_key = payload.dedup_key

  -- HARD precondition (the LAST safety boundary): open_pr NEVER opens an uninvited
  -- PR, UNCONDITIONALLY. The invite is re-derived fresh from the UPSTREAM candidate
  -- thread (source_ref on FKST_CONTRIB_TARGET) - where maintainers actually reply - not
  -- trusted from the payload; no env flag can relax this boundary. The upstream gate may
  -- relax FKST_PROPOSE_REQUIRE_INVITE, but open_pr does not consult it - an uninvited PR
  -- is a ban risk (playbook DON'T #1).
  local invited = core.recorded_invite(dedup_key, entity)
  if not invited then
    log.warn("codex-saga/open_pr refuse: no recorded maintainer invitation; not opening an uninvited PR")
    return nil
  end

  -- Integrity preflight (#5), FAIL-CLOSED: never open a PR unless the root cause was
  -- VERIFIED against the fork worktree (Agent A's root_cause_verified == true). Blocking
  -- on nil too (not only an explicit false) closes the recovered-invite bypass: the cron
  -- reconcile path rebuilds codex_invited from markers and cannot carry the diagnose-time
  -- flag, so a nil MUST read as unverified here (the field is threaded on the direct path
  -- via LEARNING_KEYS). This never relaxes the hard invite gate above.
  if payload.root_cause_verified ~= true then
    log.warn("codex-saga/open_pr refuse: root_cause not verified; not opening a PR on an unverified diagnosis")
    return nil
  end

  -- Create the fork->upstream PR (dry-run by default) and the CLA comment.
  local candidate = core.parse_entity_ref(entity)
  local upstream = core.contrib_target()
  local branch = payload.demo_branch or ("codex-saga/fix-" .. core.safe_segment(dedup_key))
  local fork_owner = (core.fork_repo():match("^(.-)/") or "fork")

  local pr_intent = core.egress_write({
    op = "open-pr",
    repo = upstream,
    dedup_key = dedup_key,
    title = "Fix: " .. tostring(dedup_key),
    body = core.pr_body(payload),
    marker = core.pr_marker(dedup_key),
    argv_builder = function(path)
      return core.gh_pr_create_argv({
        base_repo = upstream,
        head = fork_owner .. ":" .. branch,
        base = "main",
        title = "Fix: " .. tostring(dedup_key),
      }, path)
    end,
  })

  -- CLA acknowledgement comment on the candidate issue / PR thread.
  if candidate ~= nil then
    core.egress_write({
      op = "cla-comment",
      repo = candidate.repo,
      dedup_key = dedup_key,
      body = core.cla_comment(),
      marker = core.pr_marker(dedup_key),
      argv_builder = function(path)
        return core.gh_issue_comment_argv(candidate.repo, candidate.number, path)
      end,
    })
  end

  local raised = {
    schema = "codex-saga.proposed.v1",
    source_ref = entity,
    dedup_key = dedup_key,
    -- carry the control-issue locator + learning metadata to the track recorder.
    control_issue = payload.control_issue,
  }
  core.merge_learning(raised, payload)
  -- Board links: the opened PR (gh stdout, real mode) + the branch it carries.
  local pr_url = core.url_from_intent(pr_intent)
  core.record_transition(dedup_key, "proposed", {
    control_issue = payload.control_issue,
    detail = pr_url ~= nil and ("PR: " .. pr_url) or ("branch: " .. core.branch_url(branch)),
  })
  raise("codex_proposed", raised)
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "open_pr",
})
