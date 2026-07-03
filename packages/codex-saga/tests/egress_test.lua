-- codex-saga egress + consensus + invite unit tests (DRY-RUN posture).
-- `tk` is the test kit; the global `t` stays the i18n function.
local core = require("core")
local tk = fkst.test

return {
  -- Default posture is dry-run (FKST_GITHUB_WRITE unset by the hermetic runner).
  test_write_mode_defaults_to_dry_run = function()
    tk.eq(core.write_mode(), "dry-run")
  end,

  test_upstream_engagement_hold_is_time_based = function()
    tk.eq(core.upstream_engagement_held(), false)
    tk.eq(core.upstream_engagement_hold_until(), nil)
  end,

  -- A write-class egress in dry-run records + returns an intent with NO external
  -- mutation: no exec_argv command is performed.
  test_egress_write_dry_run_returns_intent_without_exec = function()
    local intent = core.egress_write({
      op = "engage-comment",
      repo = "openai/codex",
      dedup_key = "d1",
      body = "diagnosis body",
      marker = core.engage_marker("d1"),
      argv_builder = function(path)
        return core.gh_issue_comment_argv("openai/codex", 1234, path)
      end,
    })
    tk.eq(intent.mode, "dry-run")
    tk.eq(intent.op, "engage-comment")
    tk.eq(intent.repo, "openai/codex")
    tk.eq(#tk.command_calls(), 0)
  end,

  -- The outward engage body MUST carry the AI-disclosure line (spec §10 gate7).
  test_engage_body_includes_ai_disclosure = function()
    local body = core.engage_body(
      { kind = "external", ref = "openai/codex#issues/1234" },
      { root_cause = "src/exec/mod.rs:88", labels = { "bug" }, score = 0.73 }
    )
    local disclosure = t("codex-saga.engage.disclose_ai")
    tk.is_true(disclosure ~= "")
    tk.is_true(body:find(disclosure, 1, true) ~= nil)
    tk.is_true(body:find("src/exec/mod.rs:88", 1, true) ~= nil)
  end,

  -- The CLA acknowledgement text is the exact required string.
  test_cla_comment_is_the_required_text = function()
    tk.eq(core.cla_comment(), "I have read the CLA Document and I hereby sign the CLA")
  end,

  -- Consensus aggregation: unanimous approve -> approve; any reject -> reject.
  test_consensus_aggregate_unanimous_approve = function()
    tk.eq(core.aggregate({ "approve", "approve" }), "approve")
  end,

  test_consensus_aggregate_any_reject = function()
    tk.eq(core.aggregate({ "approve", "reject" }), "reject")
    tk.eq(core.aggregate({}), "reject")
  end,

  test_parse_angle_output_fail_closed = function()
    tk.eq(core.parse_angle_output("VERDICT: approve"), "approve")
    tk.eq(core.parse_angle_output("VERDICT: reject"), "reject")
    tk.eq(core.parse_angle_output("garbage with no verdict"), "reject")
  end,

  -- consensus_decide with an injected runner aggregates angle verdicts.
  test_consensus_decide_with_injected_runner = function()
    local approve_runner = function(_)
      return { stdout = "VERDICT: approve", exit_code = 0 }
    end
    local outcome = core.consensus_decide({ title = "x" }, { runner = approve_runner, angles = { "alignment" } })
    tk.eq(outcome.decision, "approve")
  end,

  -- Invite re-derivation: a maintainer assignee/comment is an invite; otherwise not.
  test_invite_in_view_detects_maintainer = function()
    tk.eq(core.invite_in_view({ assignees = { { login = "gpeal" } }, comments = {} }), true)
    tk.eq(core.invite_in_view({ assignees = {}, comments = { { author = { login = "bolinfest" } } } }), true)
    tk.eq(core.invite_in_view({ assignees = { { login = "some-random-user" } }, comments = {} }), false)
    tk.eq(core.invite_in_view({}), false)
  end,

  test_is_maintainer_tolerates_bot_suffix_and_case = function()
    tk.eq(core.is_maintainer("Bolinfest"), true)
    tk.eq(core.is_maintainer("pakrym-oai[bot]"), true)
    tk.eq(core.is_maintainer("not-a-maintainer"), false)
  end,

  -- Fail-closed: an invite that cannot be read from GitHub counts as not invited.
  test_recorded_invite_fails_closed_without_data = function()
    tk.eq(core.recorded_invite("codex-triage:candidate:openai/codex#1234", nil), false)
  end,

  -- The control marker round-trips a dedup_key.
  test_control_marker_round_trips = function()
    local dedup = "codex-triage:candidate:openai/codex#1234"
    local body = "header\n" .. core.control_marker(dedup) .. "\nfooter"
    tk.eq(core.control_dedup_from_body(body), dedup)
  end,

  -- FIX 4: a marker is durable truth ONLY when bot-authored. A foreign comment/body
  -- carrying the marker string is treated as ABSENT (cannot suppress a real write).
  test_trusted_marker_requires_bot_authorship = function()
    local marker = core.engage_marker("d1")
    -- present + bot-authored -> trusted
    tk.eq(core.trusted_marker({ body = "x " .. marker, author = { login = "codex-bot" } }, marker, "codex-bot"), true)
    -- present but NON-bot author -> treated as absent
    tk.eq(core.trusted_marker({ body = "x " .. marker, author = { login = "rando" } }, marker, "codex-bot"), false)
    -- bot author but marker absent -> absent
    tk.eq(core.trusted_marker({ body = "no marker", author = { login = "codex-bot" } }, marker, "codex-bot"), false)
    -- App "[bot]" suffix + case tolerated
    tk.eq(core.trusted_marker({ body = marker, author = { login = "Codex-Bot[bot]" } }, marker, "codex-bot"), true)
    -- no configured bot login -> never trusted (fail-closed)
    tk.eq(core.trusted_marker({ body = marker, author = { login = "codex-bot" } }, marker, nil), false)
  end,

  -- FIX 2 unit: the source marker round-trips the ORIGINAL candidate source_ref.
  test_source_marker_round_trips_original_ref = function()
    local dedup = "codex-triage:candidate:openai/codex#1234"
    local body = core.control_marker(dedup) .. "\n"
      .. core.source_marker(dedup, { kind = "external", ref = "openai/codex#issues/1234" })
    local recovered = core.control_source_ref_from_body(body)
    tk.eq(recovered.kind, "external")
    tk.eq(recovered.ref, "openai/codex#issues/1234")
  end,

  -- FIX 3 follow-up unit: the durable count is gated on MARKER TRUTH, not label
  -- shape - a bot-authored record with NO engagement marker is not counted; and with
  -- no configured bot login authorship cannot be trusted, so nothing counts.
  test_durable_engagement_count_requires_marker = function()
    local marker = core.control_marker("codex-triage:candidate:openai/codex#1234")
    local with_marker = '{"author":{"login":"codex-bot"},"body":"' .. marker .. '"}'
    local without_marker = '{"author":{"login":"codex-bot"},"body":"engaged label, no marker"}'
    local injected = function(_)
      return { stdout = "[" .. with_marker .. "," .. without_marker .. "]", exit_code = 0 }
    end
    -- No FKST_GITHUB_BOT_LOGIN configured here -> authorship cannot be trusted -> 0.
    tk.eq(core.durable_engagement_count(injected), 0)
  end,
}
