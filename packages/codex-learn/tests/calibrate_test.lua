-- codex-learn advocate-calibration unit tests. The advocate's recorded verdict is
-- compared against the actual disposition; persistent false-lenience tightens the
-- strictness threshold, persistent false-strictness loosens it. Verified through
-- advocate.gate's own combine(). Pure, inline fixtures: no IO/network.
local core = require("core")
local t = fkst.test

return {
  -- advocate.gate semantics: a confident pick passes; a low-confidence pick under a
  -- higher strictness threshold is refuted (blocking dissent).
  test_gate_verdict_follows_strictness = function()
    t.eq(core.gate_verdict({ picked_score = 80 }, 45), "pass")
    t.eq(core.gate_verdict({ picked_score = 30 }, 45), "refuted")
  end,

  -- TIGHTEN: the advocate kept passing picks that then died (false-lenient), so the
  -- strictness threshold rises above the worst wrongly-passed pick (bounded by the
  -- weakest proven winner), recurring objection themes are promoted, and the wrongly-
  -- passed picks now flip to refuted under the new threshold.
  test_calibration_tightens_on_false_lenience = function()
    local cal = core.calibrate_advocate({
      { advocate_verdict = "pass", disposition = "ignored", picked_score = 50,
        review_comment_themes = { "missing_test", "style" } },
      { advocate_verdict = "pass", disposition = "closed", picked_score = 60,
        review_comment_themes = { "missing_test" } },
      { advocate_verdict = "pass", disposition = "merged", picked_score = 80 },
    }, { prior_strictness = 45 })

    t.eq(cal.recommended, "tighten")
    t.is_true(cal.strictness_delta > 0)
    t.eq(cal.new_strictness, 61) -- max(50,60)+1, capped by the weakest winner (80)
    t.eq(cal.counts.false_lenient, 2)
    t.eq(cal.counts.correct_pass, 1)
    t.eq(cal.flips_under_new_strictness, 2)
    -- the recurring objection theme is promoted to a candidate rule
    t.eq(cal.valid_objection_themes[1], "missing_test")
  end,

  -- LOOSEN: the advocate kept refuting picks that would have merged (false-strict), so
  -- the threshold drops to re-admit the weakest wrongly-refuted winner.
  test_calibration_loosens_on_false_strictness = function()
    local cal = core.calibrate_advocate({
      { advocate_verdict = "refuted", disposition = "merged", picked_score = 30 },
      { advocate_verdict = "refuted", disposition = "merged", picked_score = 35 },
      { advocate_verdict = "refuted", disposition = "ignored", picked_score = 20 },
    }, { prior_strictness = 45 })

    t.eq(cal.recommended, "loosen")
    t.is_true(cal.strictness_delta < 0)
    t.eq(cal.new_strictness, 29) -- min wrongly-refuted winner (30) - 1
    t.eq(cal.counts.false_strict, 2)
    t.eq(cal.counts.correct_refute, 1)
  end,

  -- HOLD: balanced error (equal false-lenient and false-strict) leaves strictness put.
  test_calibration_holds_when_balanced = function()
    local cal = core.calibrate_advocate({
      { advocate_verdict = "pass", disposition = "ignored", picked_score = 50 },
      { advocate_verdict = "refuted", disposition = "merged", picked_score = 40 },
    }, { prior_strictness = 45 })
    t.eq(cal.recommended, "hold")
    t.eq(cal.strictness_delta, 0)
  end,
}
