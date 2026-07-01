-- libraries/advocate unit tests, exercised through this consuming package (the
-- guide's library-test mechanism). Asserts the PURE, DEPENDENCY-INVERTED devil's
-- -advocate gate (learning-model §7/§9): a `decide` function is INJECTED (no hard
-- dependency on any consensus implementation), the advocate appends a dissent
-- angle, and the combined verdict is fail-closed. No IO.
-- G5: every *_test.lua must yield >=1 passing engine test.
local advocate = require("advocate.gate")
local t = fkst.test

-- A stub consensus/decision function (the injected dependency). It records the
-- angles it was handed and returns a fixed decision, so tests can prove the
-- advocate injected dissent without importing any real consensus engine.
local function stub_decide(decision, captured)
  return function(request)
    if captured then
      captured.request = request
    end
    return { decision = decision, reason = "stub:" .. decision }
  end
end

return {
  -- approve + non-blocking dissent -> the gate passes.
  test_review_passes_on_approve_without_blocking_dissent = function()
    local verdict = advocate.review({
      subject = { title = "exec panic regression" },
      decide = stub_decide("approve"),
    })
    t.eq(verdict.verdict, "pass")
    t.eq(verdict.refuted, false)
    t.eq(verdict.decision, "approve")
  end,

  -- a non-approve consensus decision -> refuted (fail-closed).
  test_review_refutes_on_non_approve = function()
    local verdict = advocate.review({
      subject = { title = "low-value duplicate" },
      decide = stub_decide("reject"),
    })
    t.eq(verdict.verdict, "refuted")
    t.eq(verdict.refuted, true)
    t.eq(verdict.decision, "reject")
    t.is_true(type(verdict.reason) == "string")
  end,

  -- dependency inversion: the advocate must APPEND a dissent angle before calling
  -- the injected decision, and surface that dissent in the combined verdict.
  test_review_injects_dissent_angle = function()
    local captured = {}
    advocate.review({
      subject = { title = "mcp handshake bug" },
      angles = { { angle = "minimal" }, { angle = "structural" } },
      decide = stub_decide("approve", captured),
    })
    local angles = captured.request.angles
    -- two base angles + exactly one appended dissent angle.
    t.eq(#angles, 3)
    t.eq(angles[3].stance, "dissent")
  end,

  -- a blocking dissent refutes even when the injected consensus approves: the
  -- advocate is the guardrail against an echo chamber (learning-model §9).
  test_review_blocking_dissent_overrides_approve = function()
    local verdict = advocate.review({
      subject = { title = "confident but unreproducible pick" },
      decide = stub_decide("approve"),
      dissent = function(_subject)
        return { angle = "devils-advocate", stance = "dissent", blocking = true, objection = "not reproducible" }
      end,
    })
    t.eq(verdict.verdict, "refuted")
    t.eq(verdict.reason, "not reproducible") -- the dissent objection is surfaced
  end,

  -- the injected decision is REQUIRED (dependency inversion, fail-closed).
  test_review_requires_injected_decide = function()
    t.raises(function()
      advocate.review({ subject = { title = "x" } })
    end)
    t.raises(function()
      advocate.review("not a table")
    end)
  end,

  -- build_dissent default produces a non-blocking, subject-titled objection.
  test_build_dissent_default_is_non_blocking = function()
    local dissent = advocate.build_dissent({ title = "exec panic" })
    t.eq(dissent.stance, "dissent")
    t.eq(dissent.blocking, false)
    t.is_true(type(dissent.objection) == "string")
  end,
}
