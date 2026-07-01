-- codex-triage/score_dedup department integration tests. Drive the pipeline
-- directly via run_department with an INJECTED payload (issues / clusters /
-- target) so the suite needs NO network or IO. Asserts: ATTEMPT issues raise the
-- FROZEN codex_candidate contract {source_ref, dedup_key, schema, score}, dedup
-- collapses members onto the representative, and non-ATTEMPT issues never raise.
-- G5: every *_test.lua must yield >=1 passing engine test.
local t = fkst.test

-- A Tier-A regression winner (scores ATTEMPT). Shape from worked_on_full.jsonl.
local function regression_winner(number)
  return {
    number = number,
    title = "regression: exec panics after update",
    labels = { "bug", "regression", "exec" },
    reactions = 25,
    body = "What version of Codex CLI is running? codex-cli 0.137.0\n"
      .. "Steps to reproduce:\n1. run codex exec\n```\ncodex exec foo\n```\n"
      .. "Observed: panic / error on macOS.",
  }
end

local function tier_d_issue(number)
  return {
    number = number,
    title = "app crashes",
    labels = { "app", "browser" },
    reactions = 8,
    body = "Version 1.0. Steps to reproduce. Error on macOS.",
  }
end

local function enhancement_issue(number)
  return {
    number = number,
    title = "please add a flag",
    labels = { "enhancement" },
    reactions = 2,
    body = "It would be nice to have a new option.",
  }
end

return {
  -- Two clustered ATTEMPT regressions: only the representative (#4243, more
  -- reactions) is raised; the duplicate (#4242) collapses onto it. Tier-D and
  -- enhancement issues never raise.
  test_attempt_representative_raises_frozen_candidate_payload = function()
    local result = t.run_department("departments/score_dedup/main.lua", {
      queue = "codex_issue_poll_tick",
      payload = {
        target = "openai/codex",
        clusters = {
          { members = { { n = 4242, reactions = 3 }, { n = 4243, reactions = 10 } } },
        },
        issues = {
          regression_winner(4243), -- cluster representative -> raised
          regression_winner(4242), -- duplicate member -> collapsed (not raised)
          tier_d_issue(5001), -- hard drop
          enhancement_issue(5002), -- SKIP bin
        },
      },
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)

    local raised = result.raises[1]
    -- The engine reports the raised queue fully-qualified with its owner
    -- namespace - exactly the form the sibling codex-saga consumes.
    t.eq(raised.queue, "codex-triage.codex_candidate")

    local p = raised.payload
    -- Frozen contract: exactly {source_ref, dedup_key, schema, score}.
    t.eq(p.schema, "codex-triage.candidate.v1")
    t.eq(p.source_ref.kind, "external")
    t.eq(p.source_ref.ref, "openai/codex#issues/4243")
    t.eq(p.dedup_key, "codex-triage:dup:openai/codex#4243")
    t.is_true(type(p.score) == "number")
    t.is_true(p.score >= 58)
    -- Payload discipline: NEVER inline the issue body / title / labels.
    t.is_nil(p.body)
    t.is_nil(p.title)
    t.is_nil(p.labels)
  end,

  -- EDGE (funnel order): a cluster whose representative (#7100, most reactions)
  -- bins BELOW ATTEMPT but whose non-representative member (#7101) bins ATTEMPT
  -- must still raise EXACTLY ONE candidate (the cluster is not dropped). The
  -- candidate carries the chosen member's own source_ref and the cluster
  -- representative's dedup_key. Pre-scoring dedup (the bug) would raise zero.
  test_cluster_with_non_representative_attempt_member_still_raises = function()
    local representative_not_attempt = {
      number = 7100,
      title = "crash, but thin report",
      labels = { "bug" }, -- Tier-B, but no repro/version -> repro_ok false -> CANDIDATE
      reactions = 50, -- most reactions -> cluster representative
      body = "It just crashes for me sometimes.",
    }
    local member_is_attempt = {
      number = 7101,
      title = "regression: exec panics after update",
      labels = { "bug", "exec" }, -- Tier-A
      reactions = 5,
      body = "What version of Codex CLI is running? codex-cli 0.137.0\n"
        .. "Steps to reproduce:\n1. run codex exec\n```\ncodex exec foo\n```\n"
        .. "Observed: panic / error on macOS.",
    }

    local result = t.run_department("departments/score_dedup/main.lua", {
      queue = "codex_issue_poll_tick",
      payload = {
        target = "openai/codex",
        clusters = {
          { members = { { n = 7100, reactions = 50 }, { n = 7101, reactions = 5 } } },
        },
        issues = { representative_not_attempt, member_is_attempt },
      },
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1) -- NOT zero: the cluster survives via its ATTEMPT member

    local p = result.raises[1].payload
    t.eq(p.schema, "codex-triage.candidate.v1")
    -- dedup_key collapses to the cluster representative (#7100)...
    t.eq(p.dedup_key, "codex-triage:dup:openai/codex#7100")
    -- ...while source_ref points at the chosen ATTEMPT member (#7101).
    t.eq(p.source_ref.ref, "openai/codex#issues/7101")
    t.is_true(p.score >= 58)
  end,

  test_no_attemptable_issues_raises_nothing = function()
    local result = t.run_department("departments/score_dedup/main.lua", {
      queue = "codex_issue_poll_tick",
      payload = {
        target = "openai/codex",
        clusters = {},
        issues = {
          tier_d_issue(6001),
          enhancement_issue(6002),
        },
      },
    })
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,
}
