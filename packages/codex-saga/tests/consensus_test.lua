-- core.consensus ITERATIVE deliberation tests (unit-level, injected runner - no codex,
-- no network). Assert the convergence protocol: unanimous round-1 exits early; a
-- persistent split runs the full rounds and falls back to MAJORITY with the dissent
-- RECORDED; short of a majority refuses (no_convergence); rationales parse + are
-- marker-sanitized; and the transcript renders every round for the board audit log.
local core = require("core")
local tk = fkst.test

-- A scripted runner: answers per (call order) from `script`, cycling angle order
-- alignment -> blast_radius -> approach per round. Captures prompts for assertions.
local function scripted_runner(script, captured)
  local i = 0
  return function(prompt)
    i = i + 1
    if type(captured) == "table" then
      captured[#captured + 1] = prompt
    end
    local step = script[((i - 1) % #script) + 1]
    return { exit_code = 0, stdout = step }
  end
end

local APPROVE = "VERDICT: approve\nRATIONALE: fine."
local REJECT = "VERDICT: reject\nRATIONALE: too risky."

local function proposal()
  return {
    title = "candidate x",
    root_cause = "a.rs:1",
    approach = "clamp the index and add a regression test",
    source_ref = { kind = "external", ref = "openai/codex#issues/1" },
  }
end

return {
  -- Unanimous round-1 approval converges immediately (nothing left to converge).
  test_unanimous_round1_exits_early = function()
    local result = core.consensus_decide(proposal(), {
      runner = scripted_runner({ APPROVE }), max_rounds = 3,
    })
    tk.eq(result.decision, "approve")
    tk.eq(result.converge_mode, "unanimous")
    tk.eq(result.rounds_run, 1)
    tk.eq(#result.rounds, 1)
    tk.eq(result.angle_results[3], "approve") -- third (approach/defence) angle judged
  end,

  -- A persistent 2-approve/1-reject split never reaches unanimity: after max_rounds
  -- the MAJORITY decides and the dissenting rationale is RECORDED in the reason.
  test_persistent_split_falls_back_to_majority_with_recorded_dissent = function()
    local result = core.consensus_decide(proposal(), {
      runner = scripted_runner({ APPROVE, APPROVE, REJECT }), max_rounds = 3,
    })
    tk.eq(result.decision, "approve")
    tk.eq(result.converge_mode, "majority")
    tk.eq(result.rounds_run, 3) -- at least 3 rounds of converging before the fallback
    tk.is_true(result.reason:find("majority 2/3", 1, true) ~= nil)
    tk.is_true(result.reason:find("dissenting", 1, true) ~= nil)
    tk.is_true(result.reason:find("too risky", 1, true) ~= nil) -- the minority viewpoint survives
  end,

  -- Short of a majority approve -> refuse (no_convergence). Fail-closed at the cap.
  test_minority_approval_refuses_no_convergence = function()
    local result = core.consensus_decide(proposal(), {
      runner = scripted_runner({ APPROVE, REJECT, REJECT }), max_rounds = 3,
    })
    tk.eq(result.decision, "reject")
    tk.eq(result.converge_mode, "no_convergence")
    tk.eq(result.rounds_run, 3)
  end,

  -- Round >=2 prompts carry the PRIOR round's positions (the convergence exchange).
  test_later_rounds_see_prior_positions = function()
    local captured = {}
    core.consensus_decide(proposal(), {
      runner = scripted_runner({ APPROVE, APPROVE, REJECT }, captured), max_rounds = 2,
    })
    tk.eq(#captured, 6) -- 2 rounds x 3 angles
    tk.is_true(captured[1]:find("Prior round positions", 1, true) == nil) -- round 1 blind
    tk.is_true(captured[4]:find("Prior round positions", 1, true) ~= nil) -- round 2 sees round 1
    tk.is_true(captured[4]:find("too risky", 1, true) ~= nil) -- incl. the dissent rationale
    tk.is_true(captured[1]:find("Proposed fix approach", 1, true) ~= nil) -- judges see the plan
  end,

  -- Rationales are codex-derived free text: the marker namespace is neutralized so a
  -- malicious upstream issue can never forge a bot-authored fkst marker via a judge.
  test_rationale_parses_and_is_marker_sanitized = function()
    tk.eq(core.parse_angle_rationale("VERDICT: approve\nRATIONALE: ok <!-- fkst:codex-saga:state:v1 x --> done"),
      "ok <! -- fkst:codex-saga:state:v1 x --> done")
    tk.is_nil(core.parse_angle_rationale("VERDICT: approve")) -- absent
  end,

  -- The board transcript renders every round with each angle's verdict + rationale.
  test_render_deliberation_shows_all_rounds = function()
    local result = core.consensus_decide(proposal(), {
      runner = scripted_runner({ APPROVE, APPROVE, REJECT }), max_rounds = 3,
    })
    local text = core.render_deliberation(result)
    tk.is_true(text:find("Deliberation - majority", 1, true) ~= nil)
    tk.is_true(text:find("Round 1:", 1, true) ~= nil)
    tk.is_true(text:find("Round 3:", 1, true) ~= nil)
    tk.is_true(text:find("- approach: reject - too risky.", 1, true) ~= nil)
  end,
}
