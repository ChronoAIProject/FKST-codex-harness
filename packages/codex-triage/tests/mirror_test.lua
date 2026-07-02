-- codex-triage MIRROR + fail-closed + top-N-cap tests. The reconcile producer
-- (scripts/reconcile_issues.py) writes the durable mirror OUT OF BAND; codex-triage
-- (stateless_adapter) only READS it. Asserts: the compact JSONL mirror parses (no
-- bodies); an absent mirror + no injection FAILS CLOSED (raises nothing, never an
-- in-tick live pull); and FKST_TRIAGE_MAX_CANDIDATES bounds the diagnose fan-out.
-- G5: every *_test.lua must yield >=1 passing engine test.
local core = require("core")
local t = fkst.test

local function json_escape(s)
  return tostring(s):gsub('[%c\\"]', function(c)
    if c == "\\" then return "\\\\" end
    if c == '"' then return '\\"' end
    if c == "\n" then return "\\n" end
    if c == "\r" then return "\\r" end
    if c == "\t" then return "\\t" end
    return string.format("\\u%04x", string.byte(c))
  end)
end

local function outcome_line(dedup_key, disposition, state)
  return '{"dedup_key":"' .. json_escape(dedup_key) .. '","disposition":'
    .. (disposition and ('"' .. json_escape(disposition) .. '"') or "null")
    .. ',"state":'
    .. (state and ('"' .. json_escape(state) .. '"') or "null")
    .. '}\n'
end

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

  test_single_flight_blocks_when_latest_outcome_is_active = function()
    local path = (os.getenv("FKST_RUNTIME_ROOT") or ".") .. "/triage-single-flight-active.jsonl"
    file.write(path, outcome_line("codex-triage:dup:openai/codex#9001", "cleared", "engage"))

    local result = t.run_department("departments/score_dedup/main.lua", {
      queue = "codex_issue_poll_tick",
      payload = {
        target = "openai/codex",
        clusters = {},
        issues = { winner(9002, 70) },
      },
    }, { env = { FKST_TRIAGE_SINGLE_FLIGHT = "1", FKST_TRIAGE_OUTCOMES_PATH = path } })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_single_flight_skips_finalized_candidates_and_raises_next = function()
    local path = (os.getenv("FKST_RUNTIME_ROOT") or ".") .. "/triage-single-flight-final.jsonl"
    file.write(path, outcome_line("codex-triage:dup:openai/codex#9001", "dropped", "needs_info"))

    local result = t.run_department("departments/score_dedup/main.lua", {
      queue = "codex_issue_poll_tick",
      payload = {
        target = "openai/codex",
        clusters = {},
        issues = { winner(9001, 80), winner(9002, 70) },
      },
    }, { env = { FKST_TRIAGE_SINGLE_FLIGHT = "1", FKST_TRIAGE_OUTCOMES_PATH = path } })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.dedup_key, "codex-triage:dup:openai/codex#9002")
  end,

  -- ---- REMOTE claim ledger (cross-substrate; tracker control issues) ---------

  -- A gh tracker row parses to (dedup_key, current stage): the control marker carries
  -- the key, the swapped codex-saga:<phase|terminal> label carries the stage (candidate
  -- is a locator, prio-* tags are skipped, engaged only a fallback stage).
  test_claim_from_issue_parses_marker_and_stage = function()
    local dedup, stage = core.claim_from_issue({
      number = 12,
      body = "prose\n<!-- fkst:codex-saga:control:codex-triage:dup:openai/codex#9001 -->\n",
      labels = { { name = "codex-saga:candidate" }, { name = "codex-saga:prio-high" },
        { name = "codex-saga:1/6-diagnose" } },
    })
    t.eq(dedup, "codex-triage:dup:openai/codex#9001")
    t.eq(stage, "1/6-diagnose")
    t.is_true(not core.remote_claim_is_final(stage))
    t.is_true(core.remote_claim_is_final("needs-info"))
    t.is_true(core.remote_claim_is_final("rejected"))
    -- no marker -> no claim
    t.is_nil((core.claim_from_issue({ body = "no marker here", labels = {} })))
  end,

  -- Unit path (no env flag, injected exec): the ledger parses rows; a STALE non-final
  -- claim (updatedAt older than the lease TTL) is RELEASED so a dead substrate cannot
  -- block the fleet; a FRESH claim (unparseable/missing updatedAt counts as fresh)
  -- stays claimed.
  test_read_remote_claims_releases_stale_lease = function()
    local body = json_escape("<!-- fkst:codex-saga:control:codex-triage:dup:openai/codex#9001 -->")
    local body2 = json_escape("<!-- fkst:codex-saga:control:codex-triage:dup:openai/codex#9002 -->")
    local fake_exec = function(_opts)
      return {
        exit_code = 0,
        stdout = '[{"number":12,"body":"' .. body
          .. '","labels":[{"name":"codex-saga:candidate"},{"name":"codex-saga:1/6-diagnose"}],"updatedAt":"2020-01-01T00:00:00Z"},'
          .. '{"number":13,"body":"' .. body2
          .. '","labels":[{"name":"codex-saga:candidate"},{"name":"codex-saga:2/6-implement"}]}]',
      }
    end
    local claims = core.read_remote_claims(fake_exec)
    t.is_true(type(claims) == "table")
    t.is_nil(claims["codex-triage:dup:openai/codex#9001"]) -- stale lease released
    t.eq(claims["codex-triage:dup:openai/codex#9002"], "2/6-implement") -- fresh: no updatedAt
  end,

  -- Live posture + single-flight: an OPEN non-final control issue on the tracker is
  -- another substrate's in-flight claim -> raise NOTHING this tick.
  test_remote_active_claim_blocks_single_flight = function()
    t.mock_command("gh issue list", {
      stdout = '[{"number":12,"body":"'
        .. json_escape("<!-- fkst:codex-saga:control:codex-triage:dup:openai/codex#9001 -->")
        .. '","labels":[{"name":"codex-saga:candidate"},{"name":"codex-saga:1/6-diagnose"}]}]',
    })
    local result = t.run_department("departments/score_dedup/main.lua", {
      queue = "codex_issue_poll_tick",
      payload = {
        target = "openai/codex",
        clusters = {},
        issues = { winner(9002, 70) },
      },
    }, { env = { FKST_TRIAGE_SINGLE_FLIGHT = "1", FKST_GITHUB_WRITE = "1" } })
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  -- A remotely-SETTLED claim (terminal stage label) skips that candidate but does not
  -- block the tick: the next unclaimed candidate raises.
  test_remote_finalized_claim_skips_candidate_and_raises_next = function()
    t.mock_command("gh issue list", {
      stdout = '[{"number":12,"body":"'
        .. json_escape("<!-- fkst:codex-saga:control:codex-triage:dup:openai/codex#9001 -->")
        .. '","labels":[{"name":"codex-saga:candidate"},{"name":"codex-saga:needs-info"}]}]',
    })
    local result = t.run_department("departments/score_dedup/main.lua", {
      queue = "codex_issue_poll_tick",
      payload = {
        target = "openai/codex",
        clusters = {},
        issues = { winner(9001, 80), winner(9002, 70) },
      },
    }, { env = { FKST_TRIAGE_SINGLE_FLIGHT = "1", FKST_GITHUB_WRITE = "1" } })
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.dedup_key, "codex-triage:dup:openai/codex#9002")
  end,

  -- FAIL-CLOSED: in live posture an UNREADABLE ledger (no gh mock -> the external
  -- command fails closed in test mode) raises NOTHING - never work blind while another
  -- substrate may hold a claim.
  test_remote_ledger_unreadable_fails_closed = function()
    local result = t.run_department("departments/score_dedup/main.lua", {
      queue = "codex_issue_poll_tick",
      payload = {
        target = "openai/codex",
        clusters = {},
        issues = { winner(9002, 70) },
      },
    }, { env = { FKST_GITHUB_WRITE = "1" } })
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,
}
