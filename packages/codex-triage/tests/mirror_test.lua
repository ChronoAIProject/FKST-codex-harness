-- codex-triage MIRROR + fail-closed + top-N-cap tests. The reconcile producer
-- (scripts/reconcile_issues.py) writes the durable mirror OUT OF BAND; codex-triage
-- (stateless_adapter) only READS it. Asserts: the compact JSONL mirror parses (no
-- bodies); an absent mirror + no injection FAILS CLOSED (raises nothing, never an
-- in-tick live pull); and FKST_TRIAGE_MAX_CANDIDATES bounds the diagnose fan-out.
-- G5: every *_test.lua must yield >=1 passing engine test.
local core = require("core")
local t = fkst.test

-- A Tier-A regression winner (scores ATTEMPT). Shape from worked_on_full.jsonl.
local function winner(number, reactions)
  return {
    number = number,
    title = "regression: exec panics after update",
    labels = { "bug", "regression", "exec" },
    reactions = reactions or 20,
    body = "What version of Codex CLI is running? codex-cli 0.137.0\n"
      .. "Steps to reproduce:\n1. run codex exec\n```\ncodex exec foo\n```\n"
      .. "Observed: panic / error on macOS.",
  }
end

return {
  -- The compact JSONL mirror parses to the issue array; bodies are NEVER present.
  test_load_cached_open_issues_parses_jsonl = function()
    local issues = core.load_cached_open_issues({ path = "data/fixtures/issue-mirror.fixture.jsonl" })
    t.is_true(type(issues) == "table")
    t.eq(#issues, 2)
    t.eq(issues[1].number, 16205)
    t.eq(issues[1].source_ref.ref, "openai/codex#issues/16205")
    -- the mirror carries a BOUNDED body excerpt (the rubric's anatomy score reads body[:600]);
    -- the raised codex_candidate event stays bodyless per payload discipline.
    t.is_true(type(issues[1].body) == "string" and #issues[1].body > 0)
  end,

  -- An absent mirror returns nil (so score_dedup can fail closed).
  test_load_cached_open_issues_absent_returns_nil = function()
    t.is_nil(core.load_cached_open_issues({ path = "data/fixtures/does-not-exist.jsonl" }))
  end,

  -- FAIL-CLOSED: no injected issues + no mirror -> raise NOTHING. There is no in-tick
  -- live-poll path; the 126s poll must never run inside this 30s-stall department.
  test_score_dedup_fail_closed_without_mirror = function()
    local result = t.run_department("departments/score_dedup/main.lua", {
      queue = "codex_issue_poll_tick",
      payload = { target = "openai/codex", clusters = {} },
    })
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  -- TOP-N CAP: SEVEN unclustered ATTEMPT winners, but the default cap (5) bounds the
  -- downstream diagnose/codex fan-out — only the top 5 by score raise this tick.
  -- (The env override FKST_TRIAGE_MAX_CANDIDATES isn't exercisable here: read_env goes
  -- through exec_sync, which fails closed in test mode, so the DEFAULT applies.)
  test_score_dedup_caps_candidates = function()
    local result = t.run_department("departments/score_dedup/main.lua", {
      queue = "codex_issue_poll_tick",
      payload = {
        target = "openai/codex",
        clusters = {},
        issues = {
          winner(8001, 10), winner(8002, 20), winner(8003, 30), winner(8004, 40),
          winner(8005, 50), winner(8006, 60), winner(8007, 70),
        },
      },
    })
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 5) -- 7 attempt candidates capped to the default top-5
  end,
}
