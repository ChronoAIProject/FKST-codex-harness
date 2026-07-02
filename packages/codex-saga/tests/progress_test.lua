-- core.progress dry-run tests: early-adopt + per-stage progress feed. All in DRY-RUN
-- (the hermetic runner leaves FKST_GITHUB_WRITE unset), so every helper MUST return a
-- recorded intent WITHOUT performing any real gh/git command (the defining assertion is
-- `#tk.command_calls() == 0`, mirroring the department dry-run tests).
local core = require("core")
local tk = fkst.test

local function candidate_ref()
  return { kind = "external", ref = "openai/codex#issues/1234" }
end

local DEDUP = "codex-triage:candidate:openai/codex#1234"

return {
  -- ---- adopt (ensure_control_issue) -----------------------------------------
  -- Dry-run: records the control-issue-create intent, performs NO gh command (the
  -- marker_present/argv closures that would read GitHub are never invoked in dry-run).
  test_ensure_control_issue_dry_run_records_intent_no_command = function()
    local intent = core.ensure_control_issue(DEDUP, candidate_ref(), "diagnosing")
    tk.eq(intent.mode, "dry-run")
    tk.eq(intent.op, "control-issue-create")
    tk.eq(#tk.command_calls(), 0)
  end,

  -- ---- record_transition (per-stage progress comment) -----------------------
  test_record_transition_dry_run_records_intent_no_command = function()
    local intent = core.record_transition(DEDUP, "diagnosed", { root_cause = "codex-rs/exec/mod.rs:88" })
    tk.eq(intent.mode, "dry-run")
    tk.eq(intent.op, "progress-diagnosed")
    -- The defining dry-run assertion: no real gh/git write, and no eager GitHub read.
    tk.eq(#tk.command_calls(), 0)
  end,

  -- The state is embedded in a state marker; an unsafe/oversized state fails loud BEFORE
  -- any egress (marker safety, Codex review finding).
  test_record_transition_rejects_unsafe_state = function()
    local ok = pcall(core.record_transition, DEDUP, string.rep("x", 100), {})
    tk.is_true(not ok)
  end,

  -- ---- progress_body --------------------------------------------------------
  test_progress_body_includes_heading_and_scalars = function()
    local body = core.progress_body(DEDUP, "diagnosed", { root_cause = "codex-rs/exec/mod.rs:88", reason = "" })
    tk.is_true(body:find("Diagnosed", 1, true) ~= nil) -- locale heading for the state
    tk.is_true(body:find("root_cause: codex-rs/exec/mod.rs:88", 1, true) ~= nil)
  end,

  -- ---- control_issue_number (locator) ---------------------------------------
  -- Fail-closed: an unreadable tracker scan (no gh mock -> external command fails in the
  -- hermetic runner) yields nil, so a caller never comments on a phantom issue.
  test_control_issue_number_fails_closed_when_scan_unreadable = function()
    tk.eq(core.control_issue_number(DEDUP), nil)
  end,

  -- ---- per-state label swap -------------------------------------------------
  test_set_state_label_dry_run_records_intent_no_command = function()
    local intent = core.set_state_label(DEDUP, "diagnosed", "42")
    tk.eq(intent.mode, "dry-run")
    tk.eq(intent.op, "state-label")
    tk.eq(#tk.command_calls(), 0)
  end,

  -- The numbered phase flips as the saga advances; terminals get colored tags. The
  -- terminal suffixes are mirrored in codex-triage's REMOTE_FINAL_STAGES.
  test_phase_label_maps_states_to_board_phases = function()
    tk.eq(core.phase_label("diagnosing"), "codex-saga:1/6-diagnose")
    tk.eq(core.phase_label("diagnosed"), "codex-saga:1/6-diagnose") -- same phase until implement
    tk.eq(core.phase_label("implemented"), "codex-saga:2/6-implement")
    tk.eq(core.phase_label("cleared"), "codex-saga:4/6-gate")
    tk.eq(core.phase_label("proposed"), "codex-saga:6/6-propose")
    tk.eq(core.phase_label("refused"), "codex-saga:rejected") -- terminal tag
    tk.eq(core.phase_label("needs_info"), "codex-saga:needs-info")
    tk.eq(core.phase_label("security_routed"), "codex-saga:security-routed")
    tk.is_nil(core.phase_label("not-a-state"))
  end,

  -- Score-tier priority tag (green high / amber mid / red low), scale-robust (0-1
  -- rubric scores normalize onto 0-100); nil score -> no tag.
  test_priority_label_tiers = function()
    tk.eq(core.priority_label(89), "codex-saga:prio-high")
    tk.eq(core.priority_label(0.82), "codex-saga:prio-high") -- 0-1 scale normalized
    tk.eq(core.priority_label(70), "codex-saga:prio-mid")
    tk.eq(core.priority_label(40), "codex-saga:prio-low")
    tk.is_nil(core.priority_label(nil))
  end,

  -- ---- rich control body ("fkst ai log" style) ------------------------------
  test_control_body_has_visible_args_and_hidden_markers = function()
    local body = core.control_body(DEDUP, "diagnosing", candidate_ref(),
      { score = 89, area_labels = { "tui", "bug" }, type = "bug" })
    -- visible, human-readable arguments (the "log")
    tk.is_true(body:find("## Candidate", 1, true) ~= nil)
    tk.is_true(body:find("openai/codex#1234", 1, true) ~= nil) -- upstream display (not #issues/)
    tk.is_true(body:find("Priority score", 1, true) ~= nil)
    tk.is_true(body:find("89", 1, true) ~= nil)
    tk.is_true(body:find("AI:AUTO-LOOP", 1, true) ~= nil)
    -- hidden durable markers still present so the marker parsers keep working
    tk.is_true(body:find(core.control_marker(DEDUP), 1, true) ~= nil)
    tk.is_true(body:find("fkst:codex-saga:source:v1", 1, true) ~= nil)
  end,
}
