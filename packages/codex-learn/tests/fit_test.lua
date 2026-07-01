-- codex-learn fit + acceptance-gate unit tests. The weight re-fit runs through the
-- SAME rubric scorer feature space; the §6 gate ACCEPTS a separable corpus (AUC>=0.70
-- + monotonic) and REJECTS a non-separable one. Pure, inline fixtures: no IO/network.
local core = require("core")
local t = fkst.test

-- A clearly separable corpus: Tier-A bug/regression wins vs Tier-C low-signal losses.
local function separable_corpus()
  return {
    { label = "win", area_labels = { "regression", "exec" }, type = "regression", reactions = 30,
      anatomy_flags = { version = true, repro = true, code = true, os = true, error = true } },
    { label = "win", area_labels = { "bug", "mcp" }, type = "bug", reactions = 20,
      anatomy_flags = { version = true, repro = true, error = true } },
    { label = "win", area_labels = { "bug", "tui" }, type = "bug", reactions = 15,
      anatomy_flags = { version = true, repro = true } },
    { label = "loss", area_labels = { "cli" }, type = "other", reactions = 0, anatomy_flags = {} },
    { label = "loss", area_labels = { "session" }, type = "other", reactions = 0, anatomy_flags = {} },
    { label = "loss", area_labels = { "performance" }, type = "enhancement", reactions = 0, anatomy_flags = {} },
  }
end

-- A non-separable corpus: every win has an identical-feature loss => AUC == 0.5.
local function non_separable_corpus()
  return {
    { label = "win", area_labels = { "bug", "exec" }, type = "bug", reactions = 5,
      anatomy_flags = { version = true, repro = true } },
    { label = "loss", area_labels = { "bug", "exec" }, type = "bug", reactions = 5,
      anatomy_flags = { version = true, repro = true } },
    { label = "win", area_labels = { "enhancement" }, type = "enhancement", reactions = 0, anatomy_flags = {} },
    { label = "loss", area_labels = { "enhancement" }, type = "enhancement", reactions = 0, anatomy_flags = {} },
    { label = "win", area_labels = { "cli" }, type = "other", reactions = 0, anatomy_flags = {} },
    { label = "loss", area_labels = { "cli" }, type = "other", reactions = 0, anatomy_flags = {} },
  }
end

return {
  test_auc_rank_statistic = function()
    t.eq(core.auc({ 2, 1 }, { 1, 0 }), 1.0) -- win ranked above loss
    t.eq(core.auc({ 1, 2 }, { 1, 0 }), 0.0) -- win ranked below loss
    t.eq(core.auc({ 1, 1 }, { 1, 0 }), 0.5) -- tie
    t.is_nil(core.auc({ 1, 2 }, { 1, 1 })) -- one class empty => undefined
  end,

  test_monotonicity_check = function()
    t.eq(core.is_monotonic({ 0, 0.3, 0.6, 1.0 }), true)
    t.eq(core.is_monotonic({ 0, 0.6, 0.2 }), false)
    t.eq(core.is_monotonic({ 0.5 }), true) -- single bin trivially monotonic
  end,

  -- The feature space is the rubric scorer's: a Tier-A label normalizes area to 1.0,
  -- a Tier-D (hard-drop) label collapses it to 0 -- derived through rubric.score.
  test_feature_vector_uses_rubric_scorer = function()
    local fa = core.feature_vector({ area_labels = { "exec" }, anatomy_flags = {}, reactions = 0 })
    t.eq(fa.area, 1.0)
    local fd = core.feature_vector({ area_labels = { "app" }, anatomy_flags = {}, reactions = 0 })
    t.eq(fd.area, 0) -- Tier-D hard drop -> zero area points
  end,

  -- ACCEPT path: separable corpus clears the gate.
  test_evaluate_accepts_separable_corpus = function()
    local m = core.evaluate(separable_corpus())
    t.eq(m.accepted, true)
    t.is_true(m.auc >= core.AUC_MIN)
    t.eq(m.monotonic, true)
    t.is_true(m.counts.win == 3 and m.counts.loss == 3)
  end,

  -- REJECT path: non-separable corpus fails the AUC gate, but metrics are STILL
  -- produced (so a rejected cycle is visible) -- auc is a real number, not nil.
  test_evaluate_rejects_non_separable_corpus = function()
    local m = core.evaluate(non_separable_corpus())
    t.eq(m.accepted, false)
    t.is_true(type(m.auc) == "number")
    t.is_true(m.auc < core.AUC_MIN)
  end,
}
