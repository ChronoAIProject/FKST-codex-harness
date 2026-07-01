-- core.calibrate: the advocate calibration helper (docs/learning-model.md §3/§9).
--
-- The devil's-advocate is the guardrail against an echo chamber. Here we compare the
-- advocate's RECORDED verdict against the ACTUAL disposition in `outcomes` and adjust
-- its strictness: if the advocate kept passing picks that then died (false-lenient),
-- tighten; if it kept refuting picks that would have merged (false-strict), loosen.
-- Strictness is modeled as a picked_score threshold; we VERIFY a tighter threshold
-- flips the wrongly-passed picks to "refuted" through advocate.gate's own combine().
-- PURE: no os/io/network, no globals. Invoked by relearn (one calibration per tick).
local S = {}

local advocate = require("advocate.gate")

local DEFAULT_STRICTNESS = 45 -- METHODOLOGY §5 CANDIDATE bin boundary as the seed gate.
local RECURRING = 2 -- a review theme is "valid"/promotable once it recurs.

local function picked_score(oc)
  return tonumber(oc.picked_score) or 0
end

local function is_good(oc)
  return oc.disposition == "merged"
    or oc.engagement_reaction == "invited"
    or oc.engagement_reaction == "positive"
end

local function is_bad(oc)
  return oc.disposition == "closed" or oc.disposition == "ignored"
end

function S.install(M)
  M.DEFAULT_ADVOCATE_STRICTNESS = DEFAULT_STRICTNESS

  -- gate_verdict(pick, strictness[, decide]) -> "pass" | "refuted", computed through
  -- advocate.gate semantics: the base loop proposes the pick (consensus approve); the
  -- injected dissent BLOCKS when the pick's confidence (picked_score) is below the
  -- strictness threshold. advocate.combine folds them into the fail-closed verdict.
  function M.gate_verdict(pick, strictness, decide)
    local subject = { dedup_key = pick.dedup_key or "pick", title = pick.title }
    local blocking = picked_score(pick) < strictness
    local dissent_builder = function(_)
      return {
        angle = "devils-advocate",
        stance = "dissent",
        blocking = blocking,
        objection = "picked_score below calibrated strictness threshold",
      }
    end
    decide = decide
      or function(_)
        return { decision = "approve" }
      end
    return advocate.review({ subject = subject, decide = decide, dissent = dissent_builder }).verdict
  end

  -- calibrate_advocate(outcomes[, opts]) -> the calibration delta. opts.prior_strictness
  -- seeds the current threshold (defaults to the CANDIDATE boundary).
  function M.calibrate_advocate(outcomes, opts)
    opts = opts or {}
    local prior = tonumber(opts.prior_strictness) or DEFAULT_STRICTNESS

    -- Durable-outcomes channel contract: dedup latest-wins by dedup_key (the final
    -- merged|closed line supersedes the proposed/pending one) BEFORE calibrating, and
    -- skip in-flight (pending) records -- only a resolved disposition is a learning
    -- signal the advocate's verdict can be scored against.
    outcomes = M.resolve_outcomes(outcomes)

    local false_lenient, false_strict, correct_pass, correct_refute, evaluated = 0, 0, 0, 0, 0
    local fl_scores, cp_scores, fs_scores = {}, {}, {}
    local theme_counts = {}
    local total, in_flight = 0, 0

    for _, oc in ipairs(outcomes) do
      total = total + 1
      if not M.is_resolved_outcome(oc) then
        in_flight = in_flight + 1
      else
        local verdict = oc.advocate_verdict
        if verdict == "pass" or verdict == "refuted" then
          evaluated = evaluated + 1
          local good, bad = is_good(oc), is_bad(oc)
          if verdict == "pass" and bad then
            false_lenient = false_lenient + 1
            fl_scores[#fl_scores + 1] = picked_score(oc)
            for _, theme in ipairs(oc.review_comment_themes or {}) do
              theme_counts[tostring(theme)] = (theme_counts[tostring(theme)] or 0) + 1
            end
          elseif verdict == "pass" and good then
            correct_pass = correct_pass + 1
            cp_scores[#cp_scores + 1] = picked_score(oc)
          elseif verdict == "refuted" and good then
            false_strict = false_strict + 1
            fs_scores[#fs_scores + 1] = picked_score(oc)
          elseif verdict == "refuted" and bad then
            correct_refute = correct_refute + 1
          end
        end
      end
    end

    -- New strictness. Tighten toward excluding the wrongly-passed picks (but never so
    -- far that it would start refusing proven winners); loosen toward re-admitting the
    -- wrongly-refuted winners. Move only in the direction the net error points.
    local new_strictness = prior
    if false_lenient > false_strict and #fl_scores > 0 then
      local target = -math.huge
      for _, s in ipairs(fl_scores) do
        target = math.max(target, s)
      end
      target = target + 1 -- strictly above the worst wrongly-passed pick.
      local cap = math.huge
      for _, s in ipairs(cp_scores) do
        cap = math.min(cap, s) -- do not exceed the weakest proven winner.
      end
      new_strictness = math.max(prior, math.min(target, cap))
    elseif false_strict > false_lenient and #fs_scores > 0 then
      local target = math.huge
      for _, s in ipairs(fs_scores) do
        target = math.min(target, s)
      end
      new_strictness = math.min(prior, target - 1) -- admit the weakest wrongly-refuted winner.
    end

    -- Verify (through advocate.gate) how many wrongly-passed picks the new strictness
    -- would now refute -- the concrete effect of the calibration.
    local flips = 0
    for _, s in ipairs(fl_scores) do
      local was = M.gate_verdict({ picked_score = s }, prior)
      local now = M.gate_verdict({ picked_score = s }, new_strictness)
      if was == "pass" and now == "refuted" then
        flips = flips + 1
      end
    end

    -- Promote recurring objection themes from wrongly-passed picks into candidate rules.
    local themes = {}
    for theme, count in pairs(theme_counts) do
      if count >= RECURRING then
        themes[#themes + 1] = theme
      end
    end
    table.sort(themes)

    local delta = new_strictness - prior
    local recommended = (delta > 0 and "tighten") or (delta < 0 and "loosen") or "hold"

    return {
      counts = {
        false_lenient = false_lenient,
        false_strict = false_strict,
        correct_pass = correct_pass,
        correct_refute = correct_refute,
        evaluated = evaluated,
        in_flight = in_flight,
        total = total,
      },
      prior_strictness = prior,
      new_strictness = new_strictness,
      strictness_delta = delta,
      recommended = recommended,
      flips_under_new_strictness = flips,
      valid_objection_themes = M.as_array(themes),
    }
  end
end

return S
