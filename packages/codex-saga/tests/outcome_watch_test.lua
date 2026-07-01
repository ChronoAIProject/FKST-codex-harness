-- codex-saga outcome_watch tests (FIX B; DRY-RUN, mock gh, no network). Exercise the
-- closed PR-outcome feedback loop: the PURE derivation of §5 facts from a gh PR view,
-- and the department re-deriving a mocked MERGED / CLOSED PR read-only and updating
-- the durable outcome with ZERO foreign writes.
local core = require("core")
local tk = fkst.test

-- Escape a Lua string for embedding inside a JSON string literal (markers carry `"`).
local function json_escape(s)
  return (tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"))
end

local function raises_of(result, suffix)
  local count = 0
  for _, entry in ipairs(result.raises or {}) do
    if tostring(entry.queue):find(suffix, 1, true) ~= nil then
      count = count + 1
    end
  end
  return count
end

local function raise_payload(result, suffix)
  for _, entry in ipairs(result.raises or {}) do
    if tostring(entry.queue):find(suffix, 1, true) ~= nil then
      return entry.payload
    end
  end
  return nil
end

-- Count foreign-WRITE commands among the recorded calls (reads are allowed).
local function foreign_writes(calls)
  local n = 0
  for _, call in ipairs(calls or {}) do
    local rendered = tostring(call.rendered or "")
    if rendered:find("issue create", 1, true) ~= nil
      or rendered:find("issue comment", 1, true) ~= nil
      or rendered:find("pr create", 1, true) ~= nil then
      n = n + 1
    end
  end
  return n
end

-- A bot-authored control issue body carrying the control + original-source markers.
local function control_body(dedup, original_ref)
  return core.control_marker(dedup) .. "\n"
    .. core.source_marker(dedup, { kind = "external", ref = original_ref })
end

local DEDUP = "codex-triage:candidate:openai/codex#1234"
local ORIGINAL_REF = "openai/codex#issues/1234"

-- A durable outcomes path with an existing parent (FKST_RUNTIME_ROOT), so the append
-- needs no real mkdir (external commands fail closed in test mode).
local function outcomes_env(extra)
  local env = { FKST_LEARNING_OUTCOMES_PATH = (os.getenv("FKST_RUNTIME_ROOT") or ".") .. "/ow-outcomes.jsonl" }
  for k, v in pairs(extra or {}) do
    env[k] = v
  end
  return env
end

return {
  -- PURE: a MERGED PR with green CI + a review themed "tests" -> merged/pass/positive.
  test_derive_pr_outcome_merged_pass = function()
    local derived = core.derive_pr_outcome({
      state = "MERGED",
      statusCheckRollup = { { conclusion = "SUCCESS" }, { conclusion = "SUCCESS" } },
      reviews = { { state = "APPROVED", body = "looks good, please add tests" } },
    })
    tk.eq(derived.disposition, "merged")
    tk.eq(derived.ci, "pass")
    tk.eq(derived.engagement_reaction, "positive")
    tk.is_true(#derived.review_comment_themes >= 1)
    tk.eq(derived.review_comment_themes[1], "test")
  end,

  -- PURE: a CLOSED PR with a failing check -> closed/fail.
  test_derive_pr_outcome_closed_fail = function()
    local derived = core.derive_pr_outcome({
      state = "CLOSED",
      statusCheckRollup = { { conclusion = "FAILURE" } },
      reviews = {},
    })
    tk.eq(derived.disposition, "closed")
    tk.eq(derived.ci, "fail")
  end,

  -- merge_outcome_facts upserts the re-derived facts onto the base §5 outcome.
  test_merge_outcome_facts_upserts = function()
    local base = core.build_outcome({ source_ref = { ref = ORIGINAL_REF } })
    tk.eq(base.disposition, "proposed")
    local merged = core.merge_outcome_facts(base, { ci = "pass", disposition = "merged", engagement_reaction = "positive", review_comment_themes = { "test" } })
    tk.eq(merged.disposition, "merged")
    tk.eq(merged.ci, "pass")
  end,

  -- DEPARTMENT: a mocked MERGED PR (CI pass + review themes) -> the durable outcome
  -- is updated to disposition=merged/ci=pass, with ZERO foreign writes.
  test_outcome_watch_rederives_merged_pr = function()
    tk.mock_command("gh issue list", {
      stdout = '[{"number":7,"author":{"login":"codex-bot"},"body":"' .. json_escape(control_body(DEDUP, ORIGINAL_REF)) .. '"}]',
    })
    tk.mock_command("gh pr list", {
      stdout = '[{"state":"MERGED","statusCheckRollup":[{"conclusion":"SUCCESS"}],'
        .. '"reviews":[{"state":"APPROVED","body":"nice, add tests"}],"comments":[]}]',
    })
    local result = tk.run_department("departments/outcome_watch/main.lua", {
      queue = "codex_outcome_watch_tick",
      payload = {},
    }, { env = outcomes_env({ FKST_GITHUB_BOT_LOGIN = "codex-bot" }) })
    tk.eq(result.exit_code, 0)
    tk.is_true(raises_of(result, "codex_outcome_updated") >= 1)
    local payload = raise_payload(result, "codex_outcome_updated")
    tk.eq(payload.disposition, "merged")
    tk.eq(payload.ci, "pass")
    -- READ-ONLY on the foreign plane (gh reads only); the durable append is a local
    -- file write, not a foreign write: ZERO foreign writes.
    tk.eq(foreign_writes(tk.command_calls()), 0)
  end,

  -- DEPARTMENT: a mocked CLOSED PR -> disposition=closed, still ZERO foreign writes.
  test_outcome_watch_rederives_closed_pr = function()
    tk.mock_command("gh issue list", {
      stdout = '[{"number":7,"author":{"login":"codex-bot"},"body":"' .. json_escape(control_body(DEDUP, ORIGINAL_REF)) .. '"}]',
    })
    tk.mock_command("gh pr list", {
      stdout = '[{"state":"CLOSED","statusCheckRollup":[],"reviews":[],"comments":[]}]',
    })
    local result = tk.run_department("departments/outcome_watch/main.lua", {
      queue = "codex_outcome_watch_tick",
      payload = {},
    }, { env = outcomes_env({ FKST_GITHUB_BOT_LOGIN = "codex-bot" }) })
    tk.eq(result.exit_code, 0)
    local payload = raise_payload(result, "codex_outcome_updated")
    tk.eq(payload.disposition, "closed")
    tk.eq(foreign_writes(tk.command_calls()), 0)
  end,

  -- Fail-closed: an unreadable tracker scan yields no candidates (no raise, no write).
  test_outcome_watch_fails_closed_without_data = function()
    local result = tk.run_department("departments/outcome_watch/main.lua", {
      queue = "codex_outcome_watch_tick",
      payload = {},
    }, { env = outcomes_env() })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_outcome_updated"), 0)
    tk.eq(foreign_writes(tk.command_calls()), 0)
  end,
}
