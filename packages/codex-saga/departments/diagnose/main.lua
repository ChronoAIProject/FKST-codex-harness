-- codex-saga/diagnose: the saga entry. Consumes codex-triage's published candidate,
-- reproduces + root-causes the issue on a fork worktree, and either advances to
-- dossier or drops to needs_info with a WHY. Local + read-only to the public.
--
-- G-SAGA-HEAD: static spec table at file head (after requires, before any local fn).
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  -- Cross-package consume: the candidate produced by the codex-triage sibling
  -- (declared in [event_deps]). Composed conformance loads codex-triage too.
  consumes = { "codex-triage.codex_candidate" },
  produces = { "codex_diagnosed" },
  stall_window = "30s",
}

-- done(event) is cheap + side-effect-free. There is no durable diagnose fact before
-- the control issue exists; at-least-once re-delivery re-runs the (idempotent) local
-- reproduction and the downstream dedup_key collapses duplicates, so done is false.
local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  local entity = payload.source_ref
  local dedup_key = payload.dedup_key
  local fork_path = core.fork_local_path()

  -- CLAIM the candidate on the tracker (unconditional, dry-run-safe): the control issue
  -- is the CROSS-SUBSTRATE claim ledger - other substrates' triage reads the open control
  -- issues to know which candidates are taken, so the claim must exist BEFORE the
  -- expensive reproduction work, for every candidate the saga picks up.
  core.ensure_control_issue(dedup_key, entity, "diagnosing", {
    score = payload.score,
    area_labels = payload.labels,
    type = core.classify_type(payload.labels),
  })

  -- Local reproduction needs the fork checkout. Without it we cannot reproduce:
  -- drop to needs_info with a WHY (guaranteed terminal, no foreign-plane write).
  if not core.is_nonempty_string(fork_path) then
    log.warn("codex-saga/diagnose needs_info: " .. t("codex-saga.diagnose.needs_info_no_fork")
      .. " (set FKST_FORK_LOCAL_PATH)")
    core.record_transition(dedup_key, "needs_info", { reason = "no_fork" })
    return nil
  end

  -- Serialize the expensive codex reproduction per candidate (thundering-herd
  -- debounce within a runtime; durable truth is the downstream event + dedup_key).
  local result = { reproduced = false }
  with_lock(core.step_key("diagnose", dedup_key), function()
    result = core.run_diagnosis(entity, fork_path, dedup_key)
  end)

  if not result.reproduced then
    log.warn("codex-saga/diagnose needs_info: " .. t("codex-saga.diagnose.needs_info_not_reproduced"))
    -- Durably record the pre-gate terminal DROP so the dashboard scoreboard/funnel reflects
    -- a candidate the loop attempted but couldn't reproduce. UNCONDITIONAL + local (dry-run
    -- safe, no foreign write); disposition inert to codex-learn (core.record_terminal_drop).
    core.record_terminal_drop(dedup_key, {
      state = "needs_info",
      reason = "not_reproduced",
      source_ref = entity,
      picked_score = payload.score,
      area_labels = payload.labels,
      type = core.classify_type(payload.labels),
      root_cause = result.root_cause,
    })
    core.record_transition(dedup_key, "needs_info", { reason = "not_reproduced", root_cause = result.root_cause })
    return nil
  end

  core.record_transition(dedup_key, "diagnosed", { root_cause = result.root_cause })
  raise("codex_diagnosed", {
    schema = "codex-saga.diagnosed.v1",
    source_ref = entity,
    dedup_key = dedup_key,
    score = payload.score,
    labels = payload.labels,
    root_cause = result.root_cause,
  })
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "diagnose",
})
