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

  -- Explicit operator no-op switch (the gate that implement's write-mode has but
  -- diagnose lacked; see core.diagnose_live). Spec §5 makes the read-only local
  -- reproduction legitimate, so this DEFAULTS to live. A host without codex or a fork
  -- checkout sets FKST_DIAGNOSE_SIMULATE=1 to SKIP diagnosis entirely: no claim, no
  -- codex spawn, and crucially NO fabricated needs_info/not_reproduced drop (that state
  -- must only ever come from a real, program-observed reproduction attempt, spec §6).
  -- The candidate is left unclaimed for a capable substrate to pick up.
  if not core.diagnose_live() then
    log.info("codex-saga/diagnose simulate: FKST_DIAGNOSE_SIMULATE=1 - skipping diagnosis for "
      .. tostring(dedup_key) .. " (no claim, no codex spawn, no drop)")
    return nil
  end

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
    core.record_transition(dedup_key, "needs_info", {
      reason = "not_reproduced",
      root_cause = result.root_cause,
      summary = result.evidence, -- codex's WHY it could not be reproduced
    })
    return nil
  end

  core.record_transition(dedup_key, "diagnosed", {
    root_cause = result.root_cause,
    summary = result.evidence, -- codex's observed evidence for this root cause
  })
  raise("codex_diagnosed", {
    schema = "codex-saga.diagnosed.v1",
    source_ref = entity,
    dedup_key = dedup_key,
    score = payload.score,
    labels = payload.labels,
    root_cause = result.root_cause,
    -- Honesty flags threaded to the outward comment + track (Agent B carries them from
    -- here via LEARNING_KEYS). Small control scalars, no bodies/diffs (payload discipline).
    -- root_cause_verified: true only when core.run_diagnosis confirmed the parsed
    -- file:line names a git-TRACKED file within the fork checkout with the line in range;
    -- when false the downstream comment must say "Suspected root cause" not assert it.
    root_cause_verified = result.root_cause_verified == true,
    -- reproduced: honest, VERIFIED reproduction state - NOT the codex self-report that
    -- gated the advance above. The harness performs no automated reproduction, so this
    -- is false (downstream must NOT claim verified reproduction). Flip it to a real
    -- verification signal in core.run_diagnosis when automated reproduction is built.
    reproduced = false,
  })
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "diagnose",
})
