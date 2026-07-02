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

  -- Durably record a gate REFUSAL so the deliberation funnel (learning-model §7) is
  -- retrievable even in dry-run. The append is UNCONDITIONAL + local (no foreign write);
  -- the disposition is inert to codex-learn's fold (core.deliberation). `delib` carries
  -- the per-angle verdicts on the consensus path (nil for the earlier policy gates).
  local function refuse(reason, delib)
    delib = delib or {}
    delib.reason = reason
    delib.source_ref = entity
    delib.picked_score = payload.score
    delib.area_labels = payload.labels
    core.record_deliberation(dedup_key, delib)
    -- Surface the refusal WHY on the board too (self-skips when no issue is locatable).
    core.record_transition(dedup_key, "refused", { reason = reason })
  end

  -- gate0: security/safety issues are routed privately and NEVER posted publicly.
  if has_security_label(payload.labels) then
    log.warn("codex-saga/gate gate0 drop: " .. t("codex-saga.gate.refuse_security"))
    log.info("codex-saga/gate: would route security report privately to security@openai.com")
    refuse("security")
    return nil
  end

  -- Invitation-precondition policy must be in place (the no-uninvited-PR safety).
  if core.read_env("FKST_PROPOSE_REQUIRE_INVITE") == "0" then
    log.warn("codex-saga/gate drop: " .. t("codex-saga.gate.refuse_invite_policy"))
    refuse("invite_policy")
    return nil
  end

  -- AI-disclosure must be enabled and available (spec §10 gate7).
  if core.read_env("FKST_PROPOSE_DISCLOSE_AI") == "0"
    or not core.is_nonempty_string(t("codex-saga.engage.disclose_ai")) then
    log.warn("codex-saga/gate drop: " .. t("codex-saga.gate.refuse_disclosure"))
    refuse("disclosure")
    return nil
  end

  -- Volume cap (spec §10 gate4) from DURABLE truth (survives restarts). Fail closed:
  -- an undeterminable count is treated as at/over cap so we never exceed it.
  local count = core.engagement_count()
  if count == nil or count >= core.daily_cap() then
    log.warn("codex-saga/gate drop: " .. t("codex-saga.gate.refuse_volume_cap"))
    refuse("volume_cap")
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
  -- Surface the per-angle deliberation the advocate weighed (align/blast/dissent) as a
  -- small scalar map + a judgment count - retrievable on both the refuse and pass paths.
  local angle_results = (type(verdict.consensus) == "table" and verdict.consensus.angle_results) or nil
  local consensus_angles = core.zip_angles(angle_results, verdict.dissent)
  local deliberation_count = core.deliberation_count(angle_results, verdict.dissent)
  if verdict.verdict ~= "pass" then
    log.warn("codex-saga/gate drop: " .. t("codex-saga.gate.refuse_consensus")
      .. " (advocate: " .. tostring(verdict.reason) .. ")")
    refuse("consensus", {
      advocate_verdict = verdict.verdict,
      advocate_reason = verdict.reason,
      consensus_angles = consensus_angles,
      deliberation_count = deliberation_count,
    })
    return nil
  end

  -- Durably record the gate PASS (symmetric with the refusal path) so a cleared candidate
  -- is retrievable in dry-run - otherwise its only durable home is `track`, unreachable
  -- without a real invite/PR, and the dashboard's "cleared gate" funnel stays empty.
  core.record_cleared(dedup_key, {
    state = "engage",
    source_ref = entity,
    picked_score = payload.score,
    area_labels = payload.labels,
    type = core.classify_type(payload.labels),
    advocate_verdict = verdict.verdict,
    advocate_reason = verdict.reason,
    consensus_angles = consensus_angles,
    deliberation_count = deliberation_count,
  })

  local raised = {
    schema = "codex-saga.cleared.v1",
    source_ref = entity,
    dedup_key = dedup_key,
    score = payload.score,
    labels = payload.labels,
    root_cause = payload.root_cause,
    -- the advocate verdict + the per-angle deliberation per attempt (learning-model
    -- §5/§7), threaded to track so a PASS carries its deliberation to the durable record.
    advocate_verdict = verdict.verdict,
    advocate_reason = verdict.reason,
    consensus_angles = consensus_angles,
    deliberation_count = deliberation_count,
  }
  core.merge_learning(raised, payload)
  core.record_transition(dedup_key, "cleared", {})
  raise("codex_cleared", raised)
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "gate",
})
