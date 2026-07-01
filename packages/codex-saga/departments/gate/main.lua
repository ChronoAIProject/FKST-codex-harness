-- codex-saga/gate: the safety/consensus gate before any foreign-plane write.
-- Enforces gate0 (security/safety -> security@openai.com, never public, drop), the
-- invitation-precondition policy, the volume cap, AI-disclosure presence, and
-- multi-angle consensus. Clean pass -> codex_cleared; any failure -> drop with WHY.
-- No foreign-plane write happens here.
--
-- G-SAGA-HEAD: static spec table at file head (after requires, before any local fn).
local core = require("core")
local saga = require("workflow.saga")
-- The devil's-advocate gate (learning-model §7/§9): wraps the consensus decision in
-- a fail-closed dissent so the loop never rubber-stamps its own confident picks.
local advocate = require("advocate.gate")

local spec = {
  consumes = { "codex_dossier" },
  produces = { "codex_cleared" },
  stall_window = "30s",
}

local SECURITY_LABELS = {
  ["security"] = true,
  ["safety"] = true,
  ["vulnerability"] = true,
  ["vuln"] = true,
}

local function has_security_label(labels)
  for _, label in ipairs(labels or {}) do
    if SECURITY_LABELS[tostring(label):lower()] then
      return true
    end
  end
  return false
end

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  local entity = payload.source_ref
  local dedup_key = payload.dedup_key

  -- gate0: security/safety issues are routed privately and NEVER posted publicly.
  if has_security_label(payload.labels) then
    log.warn("codex-saga/gate gate0 drop: " .. t("codex-saga.gate.refuse_security"))
    log.info("codex-saga/gate: would route security report privately to security@openai.com")
    return nil
  end

  -- Invitation-precondition policy must be in place (the no-uninvited-PR safety).
  if core.read_env("FKST_PROPOSE_REQUIRE_INVITE") == "0" then
    log.warn("codex-saga/gate drop: " .. t("codex-saga.gate.refuse_invite_policy"))
    return nil
  end

  -- AI-disclosure must be enabled and available (spec §10 gate7).
  if core.read_env("FKST_PROPOSE_DISCLOSE_AI") == "0"
    or not core.is_nonempty_string(t("codex-saga.engage.disclose_ai")) then
    log.warn("codex-saga/gate drop: " .. t("codex-saga.gate.refuse_disclosure"))
    return nil
  end

  -- Volume cap (spec §10 gate4) from DURABLE truth (survives restarts). Fail closed:
  -- an undeterminable count is treated as at/over cap so we never exceed it.
  local count = core.engagement_count()
  if count == nil or count >= core.daily_cap() then
    log.warn("codex-saga/gate drop: " .. t("codex-saga.gate.refuse_volume_cap"))
    return nil
  end

  -- Multi-angle consensus behind the devil's-advocate gate (fail-closed: a verdict
  -- only passes when consensus APPROVES and the dissent did not block). The advocate
  -- is dependency-inverted - the gate injects the consensus decision as `decide`.
  local proposal = {
    proposal_id = dedup_key,
    dedup_key = dedup_key,
    title = "openai/codex candidate " .. tostring(dedup_key),
    root_cause = payload.root_cause,
    source_ref = entity,
  }
  local verdict = advocate.review({
    decide = function(request)
      return core.consensus_decide(request.subject)
    end,
    subject = proposal,
  })
  if verdict.verdict ~= "pass" then
    log.warn("codex-saga/gate drop: " .. t("codex-saga.gate.refuse_consensus")
      .. " (advocate: " .. tostring(verdict.reason) .. ")")
    return nil
  end

  local raised = {
    schema = "codex-saga.cleared.v1",
    source_ref = entity,
    dedup_key = dedup_key,
    score = payload.score,
    labels = payload.labels,
    root_cause = payload.root_cause,
    -- the advocate verdict per attempt (learning-model §5), threaded to track.
    advocate_verdict = verdict.verdict,
    advocate_reason = verdict.reason,
  }
  core.merge_learning(raised, payload)
  raise("codex_cleared", raised)
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "gate",
})
