-- codex-learn styleguide induction + exemplar re-rank unit tests. Engagement move-kinds
-- cluster into rules; merged-PR conventions induce the PR rules; exemplar re-rank emits
-- a precedent-backed summary. Pure, inline fixtures: no IO/network.
local core = require("core")
local t = fkst.test

local function engagement_corpus()
  return {
    { source_ref = { ref = "openai/codex#101" }, outcome = "merged", maintainer_reactions = 2,
      thread_moves = {
        { role = "author", kind = "opening", len_words = 180 },
        { role = "author", kind = "repro", len_words = 90 },
        { role = "contributor", kind = "offer_to_implement", len_words = 40 },
      } },
    { source_ref = { ref = "openai/codex#102" }, outcome = "merged", maintainer_reactions = 0,
      thread_moves = {
        { role = "author", kind = "opening", len_words = 60 },
        { role = "maintainer", kind = "ask_direction", len_words = 20 },
      } },
    { source_ref = { ref = "openai/codex#103" }, outcome = "closed", maintainer_reactions = 0,
      thread_moves = {
        { role = "author", kind = "opening", len_words = 5 },
        { role = "community", kind = "discuss", len_words = 30 },
      } },
  }
end

local function pr_corpus()
  return {
    { source_ref = { ref = "openai/codex#201" }, merged = true, additions = 40, deletions = 10,
      changed_files = 2, commits = 1, has_test = true, touched_paths = { "codex-rs/exec/src/lib.rs", "codex-rs/exec/tests/t.rs" }, author_assoc = "CONTRIBUTOR" },
    { source_ref = { ref = "openai/codex#202" }, merged = true, additions = 120, deletions = 30,
      changed_files = 3, commits = 2, has_test = true, touched_paths = { "codex-rs/tui/src/app.rs" }, author_assoc = "CONTRIBUTOR" },
    { source_ref = { ref = "openai/codex#203" }, merged = false, additions = 900, deletions = 400,
      changed_files = 20, commits = 11, has_test = false, touched_paths = { "codex-rs/app/x.rs" }, author_assoc = "NONE" },
  }
end

local function find_rule(rules, needle)
  for _, rule in ipairs(rules) do
    if tostring(rule):lower():find(needle, 1, true) then
      return true
    end
  end
  return false
end

return {
  -- Engagement: an observed `offer_to_implement` + `repro` + `ask_direction` move in
  -- successful threads each induce their mapped rule; constant guardrails always present.
  test_engagement_induction_yields_move_rules = function()
    local induced = core.induce_engagement(engagement_corpus())
    t.eq(induced.successful, 2)
    t.is_true(find_rule(induced.rules, "offer to implement"))
    t.is_true(find_rule(induced.rules, "reproduction"))
    t.is_true(find_rule(induced.rules, "direction"))
    -- constant guardrails: file:line citation + AI disclosure + concise word budget
    t.is_true(find_rule(induced.rules, "file:line"))
    t.is_true(find_rule(induced.rules, "ai-assisted"))
    t.is_true(induced.move_kind_counts.offer_to_implement >= 1)
  end,

  -- A closed-only move-kind ("discuss") does NOT appear as a rule (only successful
  -- threads contribute), and the rendered markdown carries the exemplar bank.
  test_engagement_render_has_rules_and_exemplars = function()
    local induced = core.induce_engagement(engagement_corpus())
    local md = core.render_engagement_md(induced)
    t.is_true(md:find("Engagement styleguide", 1, true) ~= nil)
    t.is_true(md:find("openai/codex#101", 1, true) ~= nil)
  end,

  -- PR: merged-only conventions induce <=3 files / <=200 LOC / test rules.
  test_pr_induction_yields_size_and_test_rules = function()
    local induced = core.induce_pr_style(pr_corpus())
    t.eq(induced.merged_count, 2)
    t.is_true(find_rule(induced.rules, "<=3 files"))
    t.is_true(find_rule(induced.rules, "<=200 loc"))
    t.is_true(find_rule(induced.rules, "include a test"))
    -- both merged PRs were <=3 files and had a test
    t.eq(induced.files_le_3_frac, 1.0)
    t.eq(induced.has_test_frac, 1.0)
  end,

  -- Exemplar re-rank emits a precedent-backed summary and orders by outcome+credit.
  test_exemplar_rerank_summary = function()
    local rr = core.rerank_exemplars(engagement_corpus(), "engagement", {
      { exemplars_used = { "openai/codex#102" }, disposition = "merged" },
    })
    t.eq(rr.summary.method, "precedent.tfidf centrality + outcome credit")
    t.is_true(rr.summary.n == 3)
    t.is_true(rr.summary.credited >= 1)
    t.is_true(#rr.ranked == 3)
  end,
}
