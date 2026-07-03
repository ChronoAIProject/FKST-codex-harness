-- codex-triage rubric-config injection tests (#9: closing the learning loop). The PURE
-- scorer now takes an OPTIONAL rubric config; the consumer (core.lua) builds it from a
-- decoded area_rubric.json (tiers + fitted selection_model weights). Proves:
--   (a) a config-less / empty / default config reproduces the committed §5 scores, AND
--   (b) an injected config with different weights or tiers CHANGES the score.
-- Everything is hermetic (inline decoded tables, no IO): build_rubric_config is PURE.
-- G5: every *_test.lua must yield >=1 passing engine test.
local core = require("core")
local rubric = require("rubric.score")
local t = fkst.test

-- A Tier-A regression winner (shape from worked_on_full.jsonl). Scores ATTEMPT by default.
local function regression_winner(number)
  return {
    number = number or 26363,
    title = "regression: codex exec panics after update",
    labels = { "bug", "regression", "exec" },
    reactions = 25,
    body = "What version of Codex CLI is running? codex-cli 0.137.0\n"
      .. "Steps to reproduce:\n1. run codex exec\n```\ncodex exec foo\n```\n"
      .. "Observed: panic / error on macOS. Exception in exec pipeline.",
  }
end

return {
  -- (a) FALLBACK: nil / {} / the explicit default config all reproduce today's score+bin.
  test_configless_matches_empty_and_default_config = function()
    local issue = regression_winner()
    local base = core.score(issue)
    local empty = core.score(issue, {})
    local default = core.score(issue, rubric.default_config())
    t.eq(empty.score, base.score)
    t.eq(default.score, base.score)
    t.eq(empty.bin, base.bin)
    t.eq(default.bin, base.bin)
    t.eq(base.bin, "ATTEMPT") -- sanity: the fixture really is an ATTEMPT winner
  end,

  -- (b) WEIGHTS: doubling the area component multiplier raises the score by exactly the
  -- area points (40 for Tier-A), leaving the raw breakdown components untouched.
  test_injected_weights_change_score = function()
    local issue = regression_winner()
    local base = core.score(issue)
    local weighted = core.score(issue, { weights = { area = 2.0 } })
    t.eq(weighted.breakdown.area_tier, base.breakdown.area_tier) -- raw points unchanged
    t.eq(weighted.score, base.score + base.breakdown.area_tier) -- +40 from the 2x area weight
    t.is_true(weighted.score > base.score)
  end,

  -- weights_from_selection_model: fitted weights become SCALE-PRESERVING re-emphasis
  -- multipliers (relative to the fit prior area 1.0 / type 0.6 / anatomy 0.5 / demand 0.2,
  -- then normalized so the max attainable score stays ~97). A component the fit leaned on
  -- harder is emphasized relative to the others, and an area-heavy winner scores higher.
  test_build_config_from_selection_model_reweights = function()
    local decoded = {
      areas = { exec = { tier = "A_target" }, bug = { tier = "B_good" }, regression = { tier = "A_target" } },
      selection_model = {
        accepted = true,
        weights = { area = 2.0, type = 0.6, anatomy = 0.5, demand = 0.2 }, -- only area moved (2x prior)
      },
    }
    local cfg = core.build_rubric_config(decoded)
    t.is_true(cfg.weights.area > 1.0) -- area up-weighted vs the rest
    t.is_true(cfg.weights.type < 1.0)
    t.is_true(cfg.weights.area > cfg.weights.type)
    -- SCALE-PRESERVING: the maximum attainable score stays ~97 (§5 bins stay calibrated).
    local max_score = cfg.weights.area * 40 + cfg.weights.type * 24
      + cfg.weights.anatomy * 25 + cfg.weights.demand * 8
    t.is_true(math.abs(max_score - 97) < 1e-6)
    local issue = regression_winner()
    local base = core.score(issue)
    local relearned = core.score(issue, cfg)
    t.is_true(relearned.score > base.score) -- the fitted weights actually move the score
  end,

  -- HONESTY (scale-preserving): multiplying EVERY fitted weight by a constant carries no
  -- relative signal, so the mapping collapses to unit multipliers and scoring is UNCHANGED.
  -- Only genuine RELATIVE re-weighting moves scores - a uniform re-scale can never.
  test_uniform_weight_rescale_is_a_noop = function()
    local cfg = core.build_rubric_config({
      areas = { exec = { tier = "A_target" } },
      -- exactly 2x the fit prior {1.0, 0.6, 0.5, 0.2} across the board
      selection_model = { accepted = true, weights = { area = 2.0, type = 1.2, anatomy = 1.0, demand = 0.4 } },
    })
    for _, k in ipairs({ "area", "type", "anatomy", "demand" }) do
      t.is_true(math.abs(cfg.weights[k] - 1.0) < 1e-9)
    end
    local issue = regression_winner()
    t.eq(core.score(issue, cfg).score, core.score(issue).score)
  end,

  -- An UNACCEPTED (or absent) selection_model contributes NO weights: the scorer keeps its
  -- committed unit calibration (fail-safe against publishing a degenerate fit).
  test_unaccepted_model_keeps_committed_weights = function()
    local cfg = core.build_rubric_config({
      areas = { exec = { tier = "A_target" } },
      selection_model = { accepted = false, weights = { area = 9.0 } },
    })
    t.is_nil(cfg.weights) -- weights omitted -> literal 1.0 multipliers
    local issue = regression_winner()
    t.eq(core.score(issue, cfg).score, core.score(issue).score)
  end,

  -- (b) TIERS: a config that re-tiers exec to the D graveyard hard-drops an exec issue that
  -- otherwise scores; a config that mirrors the committed tags reproduces the default.
  test_injected_tiers_change_area_tier_and_score = function()
    local exec_only = { number = 1, labels = { "exec" }, reactions = 0, body = "a bug" }
    t.eq(core.score(exec_only).bin ~= "SKIP", true) -- Tier-A by default -> not skipped

    local demoted = core.build_rubric_config({ areas = { exec = { tier = "D_avoid_graveyard" } } })
    local dropped = core.score(exec_only, demoted)
    t.eq(dropped.bin, "SKIP")
    t.eq(dropped.skip_reason, "SKIP-tierD") -- re-tiering exec to D changes the verdict

    -- committed tags reproduce the literal tiering (exec=A, bug=B): scores match default.
    local committed = core.build_rubric_config({
      areas = { exec = { tier = "A_target" }, bug = { tier = "B_good" } },
    })
    local bug_issue = { number = 2, labels = { "bug" }, reactions = 0, body = "x" }
    t.eq(core.area_tier({ "exec" }, committed), "A")
    t.eq(core.area_tier({ "bug" }, committed), "B")
    t.eq(core.score(bug_issue, committed).score, core.score(bug_issue).score)
  end,

  -- #21 reconciliation: `config` is Tier-A under BOTH the literal default and a config built
  -- from an area_rubric.json that tags it A_target (data + code agree per METHODOLOGY §3/§8).
  test_config_area_is_tier_a_data_and_code_agree = function()
    t.eq(core.area_tier({ "config" }), "A") -- literal default
    local cfg = core.build_rubric_config({ areas = { config = { tier = "A_target" } } })
    t.eq(core.area_tier({ "config" }, cfg), "A") -- file-derived tiers
  end,

  -- build_rubric_config returns nil for a rubric that carries neither a usable areas map
  -- nor an accepted fit, so the scorer transparently keeps its committed literals.
  test_build_config_nil_when_nothing_to_inject = function()
    t.is_nil(core.build_rubric_config({}))
    t.is_nil(core.build_rubric_config({ selection_model = { accepted = false } }))
    t.is_nil(core.build_rubric_config("not a table"))
  end,
}
