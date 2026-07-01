-- core.consensus: OWNED multi-angle consensus approval hook, mirroring the
-- `consensus` package's decide flow at a minimal, fail-closed scale.
--
-- The gate consults this BEFORE any foreign-plane write. Each angle is a read-only
-- codex judge; the aggregate is unanimous-approve-or-refuse. Consensus is a judgment
-- (no external write), so it runs regardless of dry-run posture; codex is mocked in
-- tests. Any codex failure or non-approval fails CLOSED (decision = "reject"), so an
-- unconfirmed consensus never authorizes a foreign-plane write.
local S = {}

-- The angles applied to a proposed engagement (each judged independently).
local ANGLES = { "alignment", "blast_radius" }

function S.install(M)
  M.consensus_angles = ANGLES

  -- Build the read-only judge prompt for one angle. English source (internal
  -- prompt, not outward prose), so it stays in code rather than locales.
  function M.build_angle_prompt(proposal, angle)
    local lines = {
      "You are a release-gate reviewer judging whether an open-source contribution",
      "engagement is aligned and safe to post. Judge ONLY the `" .. tostring(angle) .. "` angle.",
      "Issue: " .. tostring((proposal or {}).title or "(none)"),
      "Root cause: " .. tostring((proposal or {}).root_cause or "(unknown)"),
      "Source: " .. tostring(((proposal or {}).source_ref or {}).ref or "(none)"),
      "Respond with exactly one line: VERDICT: approve  OR  VERDICT: reject",
    }
    return table.concat(lines, "\n")
  end

  -- Parse a single angle judge's stdout into approve/reject. Fail-closed: anything
  -- that is not an explicit approve is treated as reject.
  function M.parse_angle_output(stdout)
    local verdict = tostring(stdout or ""):match("VERDICT:%s*([%a_]+)")
    if verdict ~= nil and verdict:lower() == "approve" then
      return "approve"
    end
    return "reject"
  end

  -- Aggregate angle verdicts: unanimous approve -> approve, else reject.
  function M.aggregate(angle_results)
    if type(angle_results) ~= "table" or #angle_results == 0 then
      return "reject"
    end
    for _, result in ipairs(angle_results) do
      if result ~= "approve" then
        return "reject"
      end
    end
    return "approve"
  end

  -- Run the consensus. opts.runner(prompt) -> {stdout,...} defaults to
  -- spawn_codex_sync in a read-only sandbox; opts.angles overrides the angle list.
  -- Returns { decision = "approve"|"reject", angle_results = {...} }.
  function M.consensus_decide(proposal, opts)
    opts = opts or {}
    local runner = opts.runner
    if type(runner) ~= "function" then
      runner = function(prompt)
        return spawn_codex_sync({ prompt = prompt, sandbox = "read-only", timeout = 600 })
      end
    end
    local angles = opts.angles or ANGLES
    local results = {}
    for _, angle in ipairs(angles) do
      local ok, out = pcall(runner, M.build_angle_prompt(proposal, angle))
      if not ok or type(out) ~= "table" or (out.exit_code ~= nil and out.exit_code ~= 0) then
        table.insert(results, "reject")
      else
        table.insert(results, M.parse_angle_output(out.stdout))
      end
    end
    return { decision = M.aggregate(results), angle_results = results }
  end
end

return S
