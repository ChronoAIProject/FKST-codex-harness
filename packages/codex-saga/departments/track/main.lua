-- codex-saga/track: the TERMINAL recorder (learning-model §5/§6/§7). Consumes the
-- proposed attempt, builds the outcome record (§5 schema), records it DURABLY to the
-- saga control issue (the durable GitHub mirror, spec §6) - dry-run by default, no
-- network unless FKST_GITHUB_WRITE=1 - and raises the NEW TERMINAL queue codex_tracked.
-- This is what makes codex_proposed no longer a dangling terminal; codex-learn later
-- re-derives the banks/weights from these recorded outcomes.
--
-- G-SAGA-HEAD: static spec table at file head (after requires, before any local fn).
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "codex_proposed" },
  produces = { "codex_tracked" },
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  local entity = payload.source_ref
  local dedup_key = payload.dedup_key

  -- Build the outcome record (learning-model §5 schema) from the carried learning
  -- metadata (refs/scalars only). Two channels:
  --   1. APPEND the initial record (disposition=proposed, ci=pending) to the durable
  --      outcomes JSONL codex-learn reads - UNCONDITIONAL (NOT gated by the GitHub
  --      outcome_marker; the marker gates only the visible comment below).
  --   2. Mirror it as a visible control-issue comment (dry-run by default).
  local outcome = core.build_outcome(payload)
  core.append_outcome(dedup_key, outcome)
  core.record_outcome(dedup_key, outcome, payload.control_issue)
  core.record_transition(dedup_key, "tracked", { control_issue = payload.control_issue })

  -- Terminal transition: raise codex_tracked so codex_proposed is not dangling.
  raise("codex_tracked", {
    schema = "codex-saga.tracked.v1",
    source_ref = entity,
    dedup_key = dedup_key,
    disposition = outcome.disposition,
    advocate_verdict = outcome.advocate_verdict,
  })
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "track",
})
