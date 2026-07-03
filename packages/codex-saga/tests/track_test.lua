-- codex-saga track-core unit tests (DRY-RUN posture, no network). Exercise the
-- outcome (learning-model §5) schema build, the learning-field carry, and the
-- durable record (dry-run egress -> intent, no real command).
local core = require("core")
local tk = fkst.test

local function candidate_ref()
  return { kind = "external", ref = "openai/codex#issues/1234" }
end

return {
  -- build_outcome produces the full §5 schema, defaulting the not-yet-known
  -- post-merge facts (ci/disposition) to their pending sentinels.
  test_build_outcome_has_schema_5_fields = function()
    local outcome = core.build_outcome({
      source_ref = candidate_ref(),
      picked_score = 0.73,
      labels = { "regression", "exec" },
      exemplars_used = { "openai/codex#178", "openai/codex#1" },
      advocate_verdict = "pass",
      advocate_reason = "approved",
      consensus_angles = { alignment = "approve", blast_radius = "approve", ["devils-advocate"] = "dissent" },
      deliberation_count = 3,
    })
    tk.eq(outcome.source_ref.ref, "openai/codex#issues/1234")
    tk.eq(outcome.picked_score, 0.73)
    -- §5 fold fields: area_labels (the candidate labels) + derived type.
    tk.eq(type(outcome.area_labels), "table")
    tk.eq(outcome.area_labels[1], "regression")
    tk.eq(outcome.type, "regression") -- regression takes precedence
    tk.eq(#outcome.exemplars_used, 2)
    tk.eq(outcome.engagement_reaction, "invited")
    tk.eq(outcome.ci, "pending")
    tk.eq(type(outcome.review_comment_themes), "table")
    tk.eq(outcome.disposition, "proposed")
    tk.eq(outcome.advocate_verdict, "pass")
    tk.eq(outcome.advocate_reason, "approved")
    -- deliberation signals threaded gate -> track survive into the §5 record.
    tk.eq(outcome.consensus_angles.blast_radius, "approve")
    tk.eq(outcome.deliberation_count, 3)
  end,

  -- picked_score falls back to `score`; type/area_labels default when no labels.
  test_build_outcome_falls_back_to_score = function()
    local outcome = core.build_outcome({ source_ref = candidate_ref(), score = 0.5 })
    tk.eq(outcome.picked_score, 0.5)
    tk.eq(outcome.advocate_verdict, "unknown")
    tk.eq(outcome.type, "other")
    tk.eq(type(outcome.area_labels), "table")
    tk.eq(#outcome.area_labels, 0)
  end,

  -- type classification precedence: bug, enhancement, else other.
  test_classify_type_precedence = function()
    tk.eq(core.classify_type({ "bug", "exec" }), "bug")
    tk.eq(core.classify_type({ "enhancement" }), "enhancement")
    tk.eq(core.classify_type({ "exec" }), "other")
    tk.eq(core.classify_type({}), "other")
  end,

  -- merge_learning threads the small learning fields forward, only when unset.
  test_merge_learning_copies_only_unset_fields = function()
    local out = { advocate_verdict = "pass" }
    core.merge_learning(out, {
      picked_score = 0.73,
      exemplars_used = { "openai/codex#178" },
      advocate_verdict = "refuted", -- already set on `out`; must NOT overwrite
      advocate_reason = "r",
    })
    tk.eq(out.picked_score, 0.73)
    tk.eq(#out.exemplars_used, 1)
    tk.eq(out.advocate_verdict, "pass")
    tk.eq(out.advocate_reason, "r")
  end,

  -- #8/#7: the diagnose/implement/dossier signals (demo_branch, test_command, validation,
  -- root_cause_verified, reproduced) are LEARNING_KEYS, so the gate auto-propagates them
  -- through the chain via merge_learning instead of dropping them (the "Prepared fork
  -- branch"/validation lines were unreachable downstream of the gate before this).
  test_merge_learning_carries_diagnose_and_implement_signals = function()
    local keys = {}
    for _, k in ipairs(core.learning_keys()) do
      keys[k] = true
    end
    for _, expected in ipairs({ "demo_branch", "test_command", "validation", "root_cause_verified", "reproduced" }) do
      tk.is_true(keys[expected] == true) -- present in the carry set
    end
    local out = { schema = "codex-saga.cleared.v1" }
    core.merge_learning(out, {
      demo_branch = "codex-saga/fix-openai-codex-1234",
      test_command = "cargo test -p codex-exec",
      validation = "added a focused regression test",
      root_cause_verified = true,
      reproduced = true,
    })
    tk.eq(out.demo_branch, "codex-saga/fix-openai-codex-1234")
    tk.eq(out.test_command, "cargo test -p codex-exec")
    tk.eq(out.validation, "added a focused regression test")
    tk.eq(out.root_cause_verified, true)
    tk.eq(out.reproduced, true)
  end,

  -- The rendered outcome block is a stable text record (no diffs/bodies) carrying
  -- the §5 fields, parseable later by codex-learn.
  test_render_outcome_is_stable_text = function()
    local body = core.render_outcome(core.build_outcome({
      source_ref = candidate_ref(), picked_score = 0.73,
      exemplars_used = { "openai/codex#178" }, advocate_verdict = "pass",
      consensus_angles = { alignment = "approve", blast_radius = "reject" }, deliberation_count = 3,
    }))
    tk.is_true(body:find("source_ref: openai/codex#issues/1234", 1, true) ~= nil)
    tk.is_true(body:find("exemplars_used: openai/codex#178", 1, true) ~= nil)
    tk.is_true(body:find("advocate_verdict: pass", 1, true) ~= nil)
    -- the deliberation is a logged string within the control-issue comment (sorted, stable).
    tk.is_true(body:find("consensus_angles: alignment=approve, blast_radius=reject", 1, true) ~= nil)
    tk.is_true(body:find("deliberation_count: 3", 1, true) ~= nil)
  end,

  -- render_consensus_angles degrades cleanly: nil / empty map -> "(none)".
  test_render_consensus_angles_handles_absent = function()
    tk.eq(core.render_consensus_angles(nil), "(none)")
    tk.eq(core.render_consensus_angles({}), "(none)")
  end,

  -- record_outcome is dry-run by default: it records the durable intent with NO
  -- external command (no network).
  test_record_outcome_dry_run_returns_intent = function()
    local intent = core.record_outcome("d1", core.build_outcome({ source_ref = candidate_ref() }), "7")
    tk.eq(intent.mode, "dry-run")
    tk.eq(intent.op, "track-outcome")
    tk.eq(#tk.command_calls(), 0)
  end,

  -- The outcome marker round-trips an idempotency tag and is marker-safe.
  test_outcome_marker_is_marker_safe = function()
    local marker = core.outcome_marker("codex-triage:candidate:openai/codex#1234")
    tk.is_true(marker:find("fkst:codex-saga:outcome:", 1, true) ~= nil)
  end,
}
