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
    -- Surface the refusal WHY on the board too (self-skips when no issue is locatable),
    -- including the advocate's reasoning, the per-angle verdicts, and the full
    -- multi-round deliberation transcript (the audit log).
    local summary = nil
    if core.is_nonempty_string(delib.advocate_reason) then
      summary = "advocate: " .. tostring(delib.advocate_reason)
        .. " · angles: " .. core.render_consensus_angles(delib.consensus_angles)
    end
    core.record_transition(dedup_key, "refused", {
      reason = reason,
      summary = summary,
      transcript = delib.transcript,
    })
  end

  -- gate0: security/safety issues are NEVER posted publicly. There is NO automated
  -- private-disclosure path (building one is out of scope), so we do NOT fabricate a
  -- report: the candidate is DROPPED here and routed nowhere. A human maintainer must
  -- report it out-of-band (e.g. security@openai.com) by hand if warranted.
  if has_security_label(payload.labels) then
    log.warn("codex-saga/gate gate0 drop: " .. t("codex-saga.gate.refuse_security"))
    log.info("codex-saga/gate: no automated private-disclosure path exists; the "
      .. "security candidate is DROPPED and routed NOWHERE (a maintainer must report it by hand).")
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

  -- ITERATIVE multi-angle consensus behind the devil's-advocate gate (fail-closed: a
  -- verdict only passes when consensus APPROVES and the dissent did not block). The
  -- advocate is dependency-inverted - the gate injects the consensus decision as
  -- `decide`. The proposal carries the ACTUAL fix approach (bounded scalar threaded
  -- from implement) so the judges defend/attack the real plan, and the deliberation
  -- runs rounds toward convergence (unanimity early; majority-with-recorded-dissent
  -- after the round cap; see core/consensus.lua).
  local proposal = {
    proposal_id = dedup_key,
    dedup_key = dedup_key,
    title = "openai/codex candidate " .. tostring(dedup_key),
    root_cause = payload.root_cause,
    approach = payload.approach,
    source_ref = entity,
  }
  -- The advocate's blocking threshold is the CALIBRATED strictness (learning-model
  -- §3/§9): codex-learn re-fits it from real outcomes and publishes it on the rubric;
  -- the gate consumes it here so a persistently over-lenient advocate tightens (and an
  -- over-strict one loosens). A low-confidence pick (picked_score below strictness)
  -- draws a BLOCKING dissent that refutes even an approving consensus - the guardrail
  -- against the loop rubber-stamping its own confident picks.
  local strictness = core.advocate_strictness()
  local picked_score = payload.score
  local verdict = advocate.review({
    decide = function(request)
      -- Do NOT drop request.angles: fold the injected dissent's objection into the
      -- consensus subject so the judges deliberate against the strongest counter
      -- -argument, then advocate.combine folds in the fail-closed dissent verdict.
      return core.consensus_decide(core.subject_with_dissent(request.subject, request.angles))
    end,
    subject = proposal,
    dissent = function(subject)
      return core.gate_dissent(subject, picked_score, strictness)
    end,
  })
  -- Surface the deliberation: the FINAL-round per-angle map + the totals + the full
  -- multi-round transcript (board audit log) - on both the refuse and pass paths.
  local consensus = (type(verdict.consensus) == "table") and verdict.consensus or {}
  local angle_results = consensus.angle_results
  local consensus_angles = core.zip_angles(angle_results, verdict.dissent)
  local rounds_run = tonumber(consensus.rounds_run) or 1
  -- Total judgments weighed = every angle judgment across every round + the dissent.
  local deliberation_count = rounds_run * ((type(angle_results) == "table" and #angle_results) or 0) + 1
  local transcript = core.render_deliberation(consensus)
  if verdict.verdict ~= "pass" then
    log.warn("codex-saga/gate drop: " .. t("codex-saga.gate.refuse_consensus")
      .. " (advocate: " .. tostring(verdict.reason) .. ")")
    refuse("consensus", {
      advocate_verdict = verdict.verdict,
      advocate_reason = verdict.reason,
      consensus_angles = consensus_angles,
      deliberation_count = deliberation_count,
      consensus_rounds = rounds_run,
      converge_mode = consensus.converge_mode,
      transcript = transcript,
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
    consensus_rounds = rounds_run,
    converge_mode = consensus.converge_mode,
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
    consensus_rounds = rounds_run,
    converge_mode = consensus.converge_mode,
  }
  core.merge_learning(raised, payload)
  core.record_transition(dedup_key, "cleared", {
    summary = "advocate: " .. tostring(verdict.reason or "pass")
      .. " · angles: " .. core.render_consensus_angles(consensus_angles)
      .. " · deliberations: " .. tostring(deliberation_count)
      .. " · rounds: " .. tostring(rounds_run)
      .. " (" .. tostring(consensus.converge_mode or "?") .. ")",
    transcript = transcript,
  })
  raise("codex_cleared", raised)
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "gate",
})
