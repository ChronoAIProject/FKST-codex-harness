-- advocate: the PURE devil's-advocate gate (docs/learning-model.md §7 "the
-- advocate (gate)" and §9 "the guardrail"). A loop that learns only from its own
-- confident picks becomes an echo chamber; the advocate injects dissent at every
-- gate so improvement is driven by outcomes, not self-confidence.
--
-- DEPENDENCY-INVERTED + PURE: the advocate does NOT import any concrete consensus
-- implementation (it must not hard-depend on codex-saga's internal consensus, and
-- there is no fake `consensus` package). The CALLER injects a `decide` function
-- (the real consensus/decision routine, or a test stub). The advocate appends a
-- dissent / refutation angle, runs the injected decision over the augmented angle
-- set, and folds the two into one combined verdict. No os/io/network/exec, no
-- global side effects.
local A = {}

-- build_dissent(subject, builder) -> the devil's-advocate angle that argues
-- AGAINST the proposal. If the caller injects a `builder` function it is used
-- (so the dissent itself can be a `codex` call upstream); otherwise a generic,
-- non-blocking refutation angle is synthesized from the subject.
function A.build_dissent(subject, builder)
  if type(builder) == "function" then
    return builder(subject)
  end
  local label = "(unspecified subject)"
  if type(subject) == "table" then
    if type(subject.title) == "string" then
      label = subject.title
    elseif type(subject.dedup_key) == "string" then
      label = subject.dedup_key
    end
  elseif type(subject) == "string" then
    label = subject
  end
  return {
    angle = "devils-advocate",
    stance = "dissent",
    blocking = false,
    objection = string.format(
      "Argue AGAINST proceeding with `%s`: assume it is a duplicate, out of scope, "
        .. "stale, or unreproducible, and demand the single strongest evidence-backed "
        .. "reason to proceed before approving.",
      label
    ),
  }
end

-- combine(consensus, dissent, opts) -> the single combined verdict. The advocate
-- is FAIL-CLOSED: a verdict only "passes" when the injected consensus APPROVES
-- AND the dissent did not raise a blocking objection. Anything else is "refuted"
-- and carries a greppable reason, so the gate never rubber-stamps a pick.
function A.combine(consensus, dissent, opts)
  opts = opts or {}
  local decision = "abstain"
  local reason = nil
  if type(consensus) == "table" then
    decision = consensus.decision or consensus.verdict or "abstain"
    reason = consensus.reason or consensus.framing
  elseif type(consensus) == "string" then
    decision = consensus
  end

  local dissent_blocks = type(dissent) == "table" and dissent.blocking == true
  local approved = (decision == "approve")
  local verdict = (approved and not dissent_blocks) and "pass" or "refuted"

  local out_reason = reason
  if verdict == "refuted" then
    if dissent_blocks and type(dissent) == "table" and type(dissent.objection) == "string" then
      out_reason = dissent.objection
    elseif out_reason == nil then
      out_reason = string.format(
        "advocate refuted: consensus decision `%s` did not clear the gate",
        tostring(decision)
      )
    end
  end

  return {
    verdict = verdict, -- "pass" | "refuted"
    refuted = (verdict == "refuted"),
    decision = decision, -- the raw injected-consensus decision
    reason = out_reason,
    dissent = dissent,
    consensus = consensus,
  }
end

-- review(opts) -> combined verdict (see A.combine). Dependency-inverted entry
-- point.
--
-- opts:
--   decide   REQUIRED function(request) -> consensus result. `request` is
--            { subject = opts.subject, angles = <base angles + dissent> }. The
--            result should expose `.decision` ("approve"/"reject"/"abstain"/...)
--            and optionally `.reason`/`.framing`. This is the ONLY coupling to a
--            consensus engine, and it is injected by the caller.
--   subject  the proposal / candidate / decision under review
--   angles   optional array of base angles to judge alongside the dissent
--   dissent  optional function(subject) -> a custom dissent angle (else default)
function A.review(opts)
  if type(opts) ~= "table" then
    error("advocate.review requires an options table")
  end
  local decide = opts.decide
  if type(decide) ~= "function" then
    error("advocate.review requires an injected `decide` function (dependency inversion)")
  end

  local dissent = A.build_dissent(opts.subject, opts.dissent)

  local angles = {}
  if type(opts.angles) == "table" then
    for _, angle in ipairs(opts.angles) do
      table.insert(angles, angle)
    end
  end
  table.insert(angles, dissent)

  local consensus = decide({ subject = opts.subject, angles = angles })
  return A.combine(consensus, dissent, opts)
end

return A
