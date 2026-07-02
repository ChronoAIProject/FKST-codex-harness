-- codex-saga engagement-learning unit tests (FIX A; DRY-RUN, no network). Exercise
-- the retrieval-conditioned engagement learning: precedent.tfidf retrieval over the
-- engagement corpus fixture, the induced styleguide rule consumption (injected text +
-- graceful default), and the rule+exemplar-conditioned comment composition.
local core = require("core")
local tk = fkst.test

local FIXTURE = "data/fixtures/corpus_engagement.fixture.jsonl"

return {
  -- Retrieval ranks the nearest SUCCESSFUL (merged) engagement thread by move-shape.
  -- #2417 has the opening/repro/offer_to_implement winning shape -> ranks first.
  test_retrieve_engagement_exemplars_ranks_nearest_merged = function()
    local rules = core.default_engagement_rules()
    local target = core.engagement_target({ labels = { "bug" }, root_cause = "x" }, rules)
    local exemplars = core.retrieve_engagement_exemplars(target, { path = FIXTURE, k = 3 })
    tk.is_true(#exemplars >= 1)
    tk.eq(exemplars[1].ref, "openai/codex#2417")
  end,

  -- The CLOSED thread (#11) is NOT in the exemplar bank (learn from wins only).
  test_retrieve_excludes_closed_threads = function()
    local exemplars = core.retrieve_engagement_exemplars(
      core.engagement_target({}, core.default_engagement_rules()), { path = FIXTURE, k = 10 })
    for _, exemplar in ipairs(exemplars) do
      tk.is_true(exemplar.ref ~= "openai/codex#11")
    end
  end,

  -- Styleguide: injected rule text is parsed; absent file degrades to defaults.
  test_read_engagement_styleguide_parses_and_defaults = function()
    local injected = core.read_engagement_styleguide({ text = "# Rules\n- Lead with the reproduction\n- Disclose AI assistance\n" })
    tk.eq(#injected, 2)
    tk.eq(injected[1], "Lead with the reproduction")
    -- no text -> built-in induced default rules (non-empty).
    local defaults = core.read_engagement_styleguide({ text = "" })
    tk.is_true(#defaults >= 1)
  end,

  test_styleguide_has_matches_keyword = function()
    local rules = { "Cite the root cause at file:line", "Offer to implement the fix" }
    tk.eq(core.styleguide_has(rules, "root cause"), true)
    tk.eq(core.styleguide_has(rules, "implement"), true)
    tk.eq(core.styleguide_has(rules, "nonexistent"), false)
  end,

  -- The target text encodes the induced winning move-shape so retrieval matches
  -- successful threads (not just label text).
  test_engagement_target_encodes_winning_moves = function()
    local target = core.engagement_target({ labels = { "exec" } }, core.default_engagement_rules())
    tk.is_true(target.title:find("repro", 1, true) ~= nil)
    tk.is_true(target.title:find("offer_to_implement", 1, true) ~= nil)
    tk.is_true(target.title:find("ask_direction", 1, true) ~= nil)
  end,

  -- Composition is conditioned on rules + retrieved exemplars and ALWAYS carries the
  -- mandatory AI-disclosure; it must provide a real breakdown, fix path, validation,
  -- and precedent-derived communication choices instead of a thin "I can fix this" pitch.
  test_engage_body_is_rule_and_exemplar_conditioned = function()
    local body = core.engage_body(
      { kind = "external", ref = "openai/codex#issues/1234" },
      { root_cause = "src/exec/mod.rs:88", labels = { "bug" },
        demo_branch = "codex-saga/fix-1234",
        engagement_exemplars = { "openai/codex#2417", "openai/codex#87" } }
    )
    -- mandatory disclosure + the rule-driven root-cause section.
    tk.is_true(body:find(t("codex-saga.engage.disclose_ai"), 1, true) ~= nil)
    tk.is_true(body:find("src/exec/mod.rs:88", 1, true) ~= nil)
    tk.is_true(body:find("Breakdown:", 1, true) ~= nil)
    tk.is_true(body:find("Proposed approach:", 1, true) ~= nil)
    tk.is_true(body:find("Validation plan", 1, true) ~= nil)
    tk.is_true(body:find("codex-saga/fix-1234", 1, true) ~= nil)
    -- retrieval-conditioned framing cites the exemplar count and the learned moves.
    tk.is_true(body:find("Nearest successful examples considered: 2", 1, true) ~= nil)
    tk.is_true(body:find("repro/root-cause evidence first", 1, true) ~= nil)
    -- payload discipline: no exemplar ref bodies/threads are dumped into the comment.
    tk.eq(body:find("openai/codex#2417", 1, true), nil)
    -- Regression guard for the weak public copy that prompted this fix.
    tk.eq(body:find("happy to implement whichever direction", 1, true), nil)
  end,
}
