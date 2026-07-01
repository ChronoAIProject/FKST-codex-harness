-- codex-saga saga conformance proof tests. saga_conformance_errors() must return {}
-- for the real restart table (all invariants hold) and the underlying checker must
-- flag a deliberately-broken table (a genuine check, not a constant {}).
local core = require("core")
local tk = fkst.test

return {
  test_saga_conformance_errors_empty_for_real_table = function()
    local errs = core.saga_conformance_errors()
    tk.eq(type(errs), "table")
    tk.eq(#errs, 0)
  end,

  test_restart_table_is_nontrivial = function()
    local rows = core.restart_transition_table()
    tk.is_true(#rows >= 6)
  end,

  -- The new states are present and shaped: implement is write-class with the
  -- canonical once-key; track is write-class and reaches the `tracked` terminal.
  test_restart_table_has_implement_and_track_states = function()
    local by_state = {}
    for _, row in ipairs(core.restart_transition_table()) do
      by_state[row.state] = row
    end
    tk.eq(by_state.implement.write_class, true)
    tk.eq(by_state.implement.once_key, "codex-saga/implement")
    tk.eq(by_state.track.write_class, true)
    tk.eq(by_state.track.once_key, "codex-saga/track")
    tk.eq(by_state.tracked.terminal, true)
    -- outcome_watch is a cron-driven re-derivation (read-only, no new terminal): a
    -- non-terminal that resolves into the existing `tracked` terminal.
    tk.eq(by_state.outcome_watch.terminal, false)
    tk.eq(by_state.outcome_watch.write_class, false)
    tk.eq(by_state.outcome_watch.on_timeout, "tracked")
    -- the real table passes the checker even with the new states.
    tk.eq(#core.restart_responsibility_errors(core.restart_transition_table()), 0)
  end,

  -- Injected-broken: implement with a drifted once-key is flagged (new state).
  test_checker_flags_drifted_implement_once_key = function()
    local errs = core.restart_responsibility_errors({
      { state = "implement", terminal = false, write_class = true, once_key = "codex-saga/WRONG",
        budget = { kind = "attempts", max = 3 }, on_timeout = "needs_info", successors = { "dossier", "needs_info" } },
      { state = "needs_info", terminal = true },
    })
    tk.is_true(#errs >= 1)
  end,

  -- Injected-broken: track with no budget is flagged (new state).
  test_checker_flags_track_missing_budget = function()
    local errs = core.restart_responsibility_errors({
      { state = "track", terminal = false, write_class = true, once_key = "codex-saga/track",
        on_timeout = "blocked", successors = { "tracked", "blocked" } },
      { state = "blocked", terminal = true },
      { state = "tracked", terminal = true },
    })
    tk.is_true(#errs >= 1)
  end,

  -- Injected-broken: the `tracked` terminal is unreachable when nothing reaches it.
  test_checker_flags_unreachable_tracked_terminal = function()
    local errs = core.restart_responsibility_errors({
      { state = "track", terminal = false, write_class = true, once_key = "codex-saga/track",
        budget = { kind = "attempts", max = 3 }, on_timeout = "blocked", successors = { "blocked" } },
      { state = "blocked", terminal = true },
      { state = "tracked", terminal = true },
    })
    tk.is_true(#errs >= 1)
  end,

  -- Invariant 1: a non-terminal state with no budget is flagged.
  test_checker_flags_missing_budget = function()
    local errs = core.restart_responsibility_errors({
      { state = "diagnose", terminal = false, on_timeout = "needs_info", successors = { "needs_info" } },
      { state = "needs_info", terminal = true },
    })
    tk.is_true(#errs >= 1)
  end,

  -- Invariant 2: an unreachable terminal is flagged.
  test_checker_flags_unreachable_terminal = function()
    local errs = core.restart_responsibility_errors({
      { state = "diagnose", terminal = false, budget = { kind = "attempts", max = 3 },
        on_timeout = "needs_info", successors = { "needs_info" } },
      { state = "needs_info", terminal = true },
      { state = "orphan_terminal", terminal = true },
    })
    tk.is_true(#errs >= 1)
  end,

  -- Invariant 3: a drifted write-class once-key is flagged.
  test_checker_flags_drifted_once_key = function()
    local errs = core.restart_responsibility_errors({
      { state = "engage", terminal = false, write_class = true, once_key = "codex-saga/WRONG",
        budget = { kind = "attempts", max = 3 }, on_timeout = "blocked", successors = { "blocked" } },
      { state = "blocked", terminal = true },
    })
    tk.is_true(#errs >= 1)
  end,

  -- A correct minimal table passes the checker.
  test_checker_passes_correct_minimal_table = function()
    local errs = core.restart_responsibility_errors({
      { state = "engage", terminal = false, write_class = true, once_key = "codex-saga/engage",
        budget = { kind = "attempts", max = 3 }, on_timeout = "blocked", successors = { "blocked" } },
      { state = "blocked", terminal = true },
    })
    tk.eq(#errs, 0)
  end,
}
