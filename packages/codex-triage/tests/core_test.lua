-- codex-triage core unit tests: the PURE scoring (METHODOLOGY §5), area tiers
-- (§3), bin thresholds (§5 boundaries), and dedup collapse (§7). No network/IO.
-- Fixtures are shaped from real data/worked_on_full.jsonl rows.
-- G5: every *_test.lua must yield >=1 passing engine test.
local core = require("core")
local t = fkst.test

-- A real Tier-A regression winner (shape from openai/codex#26363: bug+regression
-- +subagent, "What version of Codex CLI", repro steps, error). Scores ATTEMPT.
local function regression_winner(number, reactions)
  return {
    number = number or 26363,
    title = "regression: codex exec panics after update",
    labels = { "bug", "regression", "subagent" },
    reactions = reactions or 25,
    body = "What version of Codex CLI is running? codex-cli 0.137.0\n"
      .. "Steps to reproduce:\n1. run codex exec\n```\ncodex exec foo\n```\n"
      .. "Observed: panic / error on macOS. Exception in exec pipeline.",
  }
end

-- A real Tier-A bug winner (shape from openai/codex#29189: bug+mcp+sandbox+app
-- +browser; mcp pulls it to Tier-A even though app/browser are Tier-D).
local function bug_winner(number, reactions)
  return {
    number = number or 29189,
    title = "node_repl fails: missing field sandboxPolicy",
    labels = { "bug", "mcp", "sandbox", "app", "browser" },
    reactions = reactions or 40,
    body = "Version: Codex Desktop 26.616\nOS: macOS 26.5\n"
      .. "Problem: node_repl fails before execution.\n"
      .. "Error: missing field `sandboxPolicy`.\nMinimal repro:\n1. enable plugin",
  }
end

return {
  -- ----- area tiers (METHODOLOGY §3 R1) -----
  test_area_tier_best_label_wins = function()
    t.eq(core.area_tier({ "app", "regression" }), "A") -- regression beats Tier-D app
    t.eq(core.area_tier({ "sandbox", "cli" }), "B") -- sandbox(B) beats cli(C)
    t.eq(core.area_tier({ "cli", "app" }), "C") -- cli(C) beats app(D)
    t.eq(core.area_tier({ "app", "browser" }), "D") -- pure graveyard
    t.eq(core.area_tier({ "needs-info" }), "unknown") -- no recognized area
    t.eq(core.area_tier({ "config" }), "A") -- config is Tier-A (§3/§8 key areas)
  end,

  -- ----- type bonus (METHODOLOGY §5) -----
  test_type_bonus_precedence_and_enhancement_scaling = function()
    t.eq(select(1, core.type_bonus({ "regression", "bug" }, 0)), 24) -- regression wins
    t.eq(select(1, core.type_bonus({ "bug" }, 0)), 14)
    t.eq(select(1, core.type_bonus({ "enhancement" }, 30)), 12) -- reactions>=30
    t.eq(select(1, core.type_bonus({ "enhancement" }, 10)), 6) -- reactions>=10
    t.eq(select(1, core.type_bonus({ "enhancement" }, 2)), 1) -- low demand
    t.eq(select(1, core.type_bonus({ "documentation" }, 0)), 6) -- else branch
  end,

  -- ----- anatomy (METHODOLOGY §5; parsed from body[:600], cap 25) -----
  test_anatomy_caps_at_25_and_flags_version = function()
    local points, has_version = core.anatomy(
      "Version 1.2.3 on macOS. Steps to reproduce:\n```\ncode\n```\nError: panic stack exception"
    )
    t.eq(points, 25) -- 5+8+4+3+5 = 25 (cap)
    t.eq(has_version, true)
  end,

  test_anatomy_empty_body_is_zero = function()
    local points, has_version = core.anatomy("")
    t.eq(points, 0)
    t.eq(has_version, false)
  end,

  -- ----- demand (METHODOLOGY §5) -----
  test_demand_scales_and_caps_at_40 = function()
    t.eq(core.demand(0), 0)
    t.eq(core.demand(20), 4)
    t.eq(core.demand(40), 8)
    t.eq(core.demand(1000), 8) -- capped at 40 reactions
  end,

  -- ----- bin thresholds at the §5 boundaries -----
  test_classify_attempt_boundary = function()
    -- ATTEMPT needs score>=58 AND tier in {A,B} AND (bug|regression) AND repro_ok.
    t.eq(core.classify(58, "A", "bug", true), "ATTEMPT")
    t.eq(core.classify(57, "A", "bug", true), "CANDIDATE") -- one below the gate
    t.eq(core.classify(58, "C", "bug", true), "CANDIDATE") -- tier not A/B
    t.eq(core.classify(58, "A", "enhancement", true), "CANDIDATE") -- not bug/regression
    t.eq(core.classify(58, "A", "bug", false), "CANDIDATE") -- not repro_ok
  end,

  test_classify_candidate_low_skip_boundaries = function()
    t.eq(core.classify(45, "C", "bug", false), "CANDIDATE")
    t.eq(core.classify(44, "C", "bug", false), "LOW")
    t.eq(core.classify(32, "C", "bug", false), "LOW")
    t.eq(core.classify(31, "C", "bug", false), "SKIP")
  end,

  -- ----- full score(): winners reach ATTEMPT -----
  test_regression_winner_scores_into_attempt = function()
    local s = core.score(regression_winner())
    t.eq(s.breakdown.tier, "A")
    t.eq(s.breakdown.type, 24)
    t.eq(s.breakdown.repro_ok, true)
    t.eq(s.bin, "ATTEMPT")
    t.is_true(s.score >= 58)
    t.is_nil(s.skip_reason)
  end,

  test_bug_winner_scores_into_attempt = function()
    local s = core.score(bug_winner())
    t.eq(s.breakdown.tier, "A") -- mcp lifts it out of the app/browser graveyard
    t.eq(s.breakdown.type, 14)
    t.eq(s.bin, "ATTEMPT")
    t.is_true(s.score >= 58)
  end,

  -- ----- hard drops (METHODOLOGY §5) -----
  test_security_label_is_hard_dropped = function()
    local s = core.score({
      number = 1,
      labels = { "bug", "security" },
      reactions = 50,
      body = "Version 1.0. Steps to reproduce: leak. Error.",
    })
    t.eq(s.bin, "SKIP")
    t.eq(s.skip_reason, "SKIP-security")
    t.eq(s.score, 0)
  end,

  test_safety_check_label_is_hard_dropped_as_security = function()
    local s = core.score({ number = 2, labels = { "safety-check" }, reactions = 5, body = "x" })
    t.eq(s.skip_reason, "SKIP-security")
  end,

  test_tier_d_area_is_hard_dropped = function()
    local s = core.score({
      number = 3,
      labels = { "app", "browser" },
      reactions = 12,
      body = "Version 1.0. Steps to reproduce. Error on macOS.",
    })
    t.eq(s.bin, "SKIP")
    t.eq(s.skip_reason, "SKIP-tierD")
    t.eq(s.score, 0)
  end,

  -- ----- dedup (METHODOLOGY §7): collapse to representative = most reactions -----
  test_cluster_index_picks_most_reactions_representative = function()
    local clusters = {
      { members = { { n = 100, reactions = 2 }, { n = 200, reactions = 9 }, { n = 300, reactions = 9 } } },
    }
    local index = core.cluster_index(clusters)
    -- 200 and 300 tie on reactions; tie broken by smallest number -> 200.
    t.eq(index[100], 200)
    t.eq(index[200], 200)
    t.eq(index[300], 200)
  end,

  test_dedup_key_is_deterministic_and_collapses_members = function()
    local clusters = { { members = { { n = 100, reactions = 2 }, { n = 200, reactions = 9 } } } }
    local index = core.cluster_index(clusters)
    local key_member = core.dedup_key({ number = 100 }, index, "openai/codex")
    local key_rep = core.dedup_key({ number = 200 }, index, "openai/codex")
    t.eq(key_member, "codex-triage:dup:openai/codex#200") -- member collapses to rep
    t.eq(key_rep, "codex-triage:dup:openai/codex#200")
    t.eq(key_member, core.dedup_key({ number = 100 }, index, "openai/codex")) -- deterministic
    -- An issue outside every cluster is its own representative.
    t.eq(core.dedup_key({ number = 999 }, index, "openai/codex"), "codex-triage:dup:openai/codex#999")
  end,

  test_is_cluster_representative = function()
    local clusters = { { members = { { n = 100, reactions = 2 }, { n = 200, reactions = 9 } } } }
    local index = core.cluster_index(clusters)
    t.eq(core.is_cluster_representative({ number = 200 }, index), true)
    t.eq(core.is_cluster_representative({ number = 100 }, index), false)
    t.eq(core.is_cluster_representative({ number = 999 }, index), true) -- unclustered
  end,

  test_candidate_source_ref_is_a_stable_pointer = function()
    local ref = core.candidate_source_ref("openai/codex", 1234)
    t.eq(ref.kind, "external")
    t.eq(ref.ref, "openai/codex#issues/1234")
  end,

  -- ----- funnel order (METHODOLOGY §8): score -> bin -> ATTEMPT -> THEN dedup --
  -- The representative (#7100, most reactions) is NOT ATTEMPT, but member #7101 is.
  -- attempt_candidates must still yield one candidate for the cluster, choosing the
  -- ATTEMPT member and keying it to the representative.
  test_attempt_candidates_keeps_cluster_via_non_representative_member = function()
    local index = core.cluster_index({
      { members = { { n = 7100, reactions = 50 }, { n = 7101, reactions = 5 } } },
    })
    local rep_not_attempt = { number = 7100, labels = { "bug" }, reactions = 50, body = "it crashes" }
    local member_attempt = regression_winner(7101, 5)
    local payloads = core.attempt_candidates({ rep_not_attempt, member_attempt }, index, "openai/codex")
    t.eq(#payloads, 1)
    t.eq(payloads[1].dedup_key, "codex-triage:dup:openai/codex#7100") -- cluster key
    t.eq(payloads[1].source_ref.ref, "openai/codex#issues/7101") -- chosen member
  end,

  -- When the representative is itself ATTEMPT, it is chosen and duplicate ATTEMPT
  -- members collapse onto it (exactly one candidate per cluster).
  test_attempt_candidates_prefers_attempt_representative = function()
    local index = core.cluster_index({
      { members = { { n = 8000, reactions = 30 }, { n = 8001, reactions = 5 } } },
    })
    local payloads = core.attempt_candidates(
      { regression_winner(8001, 5), regression_winner(8000, 30) },
      index,
      "openai/codex"
    )
    t.eq(#payloads, 1)
    t.eq(payloads[1].dedup_key, "codex-triage:dup:openai/codex#8000")
    t.eq(payloads[1].source_ref.ref, "openai/codex#issues/8000") -- representative chosen
  end,

  -- Unclustered ATTEMPT issues each raise their own candidate.
  test_attempt_candidates_raises_each_unclustered_attempt = function()
    local payloads = core.attempt_candidates(
      { regression_winner(9001, 10), regression_winner(9002, 10) },
      core.cluster_index({}),
      "openai/codex"
    )
    t.eq(#payloads, 2)
  end,
}
