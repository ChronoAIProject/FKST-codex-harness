-- codex-saga invite-precondition tests (DRY-RUN, mock gh, no network). Cover:
--   #4  invite detection watches the UPSTREAM openai/codex candidate thread and derives
--       maintainer identity from authorAssociation + an API-fetched collaborators
--       allowlist (hardcoded list only as fallback), fail-closed on read failure;
--   #16 the invite-wait EXPIRY emits a terminal disposition="ignored" outcome (idempotent),
--       and does NOT fire before the window elapses;
--   #12 outcome_watch's broadened reconcile scans ALL marker-bearing control issues.
local core = require("core")
local tk = fkst.test

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

local function control_body(dedup, original_ref)
  return core.control_marker(dedup) .. "\n"
    .. core.source_marker(dedup, { kind = "external", ref = original_ref })
end

local DEDUP = "codex-triage:candidate:openai/codex#1234"
local ORIGINAL_REF = "openai/codex#issues/1234"
local function candidate_ref()
  return { kind = "external", ref = ORIGINAL_REF }
end

local function fresh_path(tag)
  return (os.getenv("FKST_RUNTIME_ROOT") or ".") .. "/invite-" .. tag .. ".jsonl"
end

-- A bot-authored engaged control issue on the tracker, carrying the control + source
-- markers and a creation timestamp (for the invite-wait expiry check).
local function engaged_list_stdout(created_at)
  return '[{"number":7,"author":{"login":"codex-bot"},"createdAt":"' .. created_at
    .. '","body":"' .. json_escape(control_body(DEDUP, ORIGINAL_REF)) .. '"}]'
end

-- An upstream candidate view where OUR bot engage comment (bearing the engage marker for
-- DEDUP) PRECEDES an optional maintainer response - the only shape that now counts as an
-- invite (a maintainer reply strictly AFTER our dossier). Requires env
-- FKST_GITHUB_BOT_LOGIN=codex-bot so the engage comment is trusted as bot-authored.
local function engaged_upstream_view(after_comment_json)
  local engage = '{"author":{"login":"codex-bot"},"authorAssociation":"NONE","body":"'
    .. json_escape(core.engage_marker(DEDUP)) .. '"}'
  local comments = engage
  if after_comment_json ~= nil then
    comments = comments .. "," .. after_comment_json
  end
  return '{"assignees":[],"comments":[' .. comments .. ']}'
end

return {
  -- ---- #4 maintainer identity (pure) ----------------------------------------
  test_is_maintainer_association = function()
    tk.eq(core.is_maintainer_association("MEMBER"), true)
    tk.eq(core.is_maintainer_association("OWNER"), true)
    tk.eq(core.is_maintainer_association("COLLABORATOR"), true)
    tk.eq(core.is_maintainer_association("member"), true) -- case-insensitive
    tk.eq(core.is_maintainer_association("CONTRIBUTOR"), false)
    tk.eq(core.is_maintainer_association("NONE"), false)
    tk.eq(core.is_maintainer_association(nil), false)
  end,

  -- is_maintainer_comment (pure): a MEMBER/OWNER/COLLABORATOR association OR an allowlisted
  -- login is a maintainer response; a non-maintainer association / unlisted login is not.
  -- (The post-engagement ORDERING is exercised by the open_pr department tests below.)
  test_is_maintainer_comment_by_association_or_allowlist = function()
    tk.eq(core.is_maintainer_comment({ author = { login = "brand-new-triager" }, authorAssociation = "MEMBER" }, {}), true)
    tk.eq(core.is_maintainer_comment({ author = { login = "drive-by" }, authorAssociation = "NONE" }, {}), false)
    tk.eq(core.is_maintainer_comment({ author = { login = "New-Maintainer" }, authorAssociation = "NONE" }, { ["new-maintainer"] = true }), true)
    tk.eq(core.is_maintainer_comment({ author = { login = "gpeal" }, authorAssociation = "NONE" }, { ["someone-else"] = true }), false)
  end,

  -- ---- #4 recorded_invite watches the UPSTREAM thread (department) -----------
  -- open_pr proceeds when a MEMBER comments on the UPSTREAM candidate thread, even though
  -- that login is NOT hardcoded (proves detection = upstream thread + authorAssociation).
  test_open_pr_proceeds_on_upstream_member_comment = function()
    tk.mock_command("gh issue view", {
      stdout = engaged_upstream_view('{"author":{"login":"unknown-oai-member"},"authorAssociation":"MEMBER","body":"looks good, please open a PR"}'),
    })
    local result = tk.run_department("departments/open_pr/main.lua", {
      queue = "codex_invited",
      payload = {
        schema = "codex-saga.invited.v1",
        dedup_key = DEDUP,
        source_ref = candidate_ref(),
        control_issue = "7",
        demo_branch = "codex-saga/fix-openai-codex-1234",
        root_cause_verified = true,
      },
    }, { env = { FKST_GITHUB_BOT_LOGIN = "codex-bot" } })
    tk.eq(result.exit_code, 0)
    tk.is_true(raises_of(result, "codex_proposed") >= 1)
  end,

  -- #5 (integrated Codex review): a maintainer comment that PREDATES our engage comment is
  -- NOT an invitation - opening a PR off pre-existing thread activity is a ban risk. Here the
  -- maintainer MEMBER comment (and an assignee) precede our bot engage comment, so open_pr
  -- REFUSES (only a response strictly after our dossier counts).
  test_open_pr_refuses_pre_engagement_maintainer_activity = function()
    tk.mock_command("gh issue view", {
      stdout = '{"assignees":[{"login":"gpeal"}],"comments":['
        .. '{"author":{"login":"gpeal"},"authorAssociation":"MEMBER","body":"old triage note"},'
        .. '{"author":{"login":"codex-bot"},"authorAssociation":"NONE","body":"' .. json_escape(core.engage_marker(DEDUP)) .. '"}'
        .. ']}',
    })
    local result = tk.run_department("departments/open_pr/main.lua", {
      queue = "codex_invited",
      payload = {
        schema = "codex-saga.invited.v1",
        dedup_key = DEDUP,
        source_ref = candidate_ref(),
        control_issue = "7",
        root_cause_verified = true,
      },
    }, { env = { FKST_GITHUB_BOT_LOGIN = "codex-bot" } })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_proposed"), 0)
  end,

  -- open_pr uses the API-fetched collaborators allowlist: a login returned by
  -- `gh api repos/.../collaborators` counts as a maintainer even at association NONE.
  test_open_pr_proceeds_on_api_allowlisted_login = function()
    tk.mock_command("gh api", { stdout = '[{"login":"api-only-maintainer"}]' })
    tk.mock_command("gh issue view", {
      stdout = engaged_upstream_view('{"author":{"login":"api-only-maintainer"},"authorAssociation":"NONE","body":"go for it"}'),
    })
    local result = tk.run_department("departments/open_pr/main.lua", {
      queue = "codex_invited",
      payload = {
        schema = "codex-saga.invited.v1",
        dedup_key = DEDUP,
        source_ref = candidate_ref(),
        control_issue = "7",
        root_cause_verified = true,
      },
    }, { env = { FKST_GITHUB_BOT_LOGIN = "codex-bot" } })
    tk.eq(result.exit_code, 0)
    tk.is_true(raises_of(result, "codex_proposed") >= 1)
  end,

  -- Fail-closed: a non-maintainer commenter (association NONE, not allowlisted, API
  -- unavailable) is NOT an invite -> open_pr REFUSES (hard gate intact, zero writes).
  test_open_pr_refuses_on_non_maintainer_upstream_comment = function()
    tk.mock_command("gh issue view", {
      stdout = '{"assignees":[],"comments":[{"author":{"login":"drive-by-user"},"authorAssociation":"NONE","body":"+1 me too"}]}',
    })
    local result = tk.run_department("departments/open_pr/main.lua", {
      queue = "codex_invited",
      payload = {
        schema = "codex-saga.invited.v1",
        dedup_key = DEDUP,
        source_ref = candidate_ref(),
        control_issue = "7",
      },
    })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_proposed"), 0)
    tk.eq(foreign_writes(tk.command_calls()), 0)
  end,

  -- Two-plane boundary: an invite on a NON-upstream repo (e.g. the fork) never satisfies
  -- the gate, even with a MEMBER comment - so maintainer standing on another repo cannot
  -- be laundered into an upstream invite. open_pr REFUSES.
  test_open_pr_refuses_invite_on_non_upstream_repo = function()
    tk.mock_command("gh issue view", {
      stdout = '{"assignees":[{"login":"gpeal"}],"comments":[{"author":{"login":"whoever"},"authorAssociation":"MEMBER","body":"ok"}]}',
    })
    local result = tk.run_department("departments/open_pr/main.lua", {
      queue = "codex_invited",
      payload = {
        schema = "codex-saga.invited.v1",
        dedup_key = DEDUP,
        -- source_ref points at the FORK, not FKST_CONTRIB_TARGET (openai/codex).
        source_ref = { kind = "external", ref = "ChronoAIProject/codex#issues/5" },
        control_issue = "7",
      },
    })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_proposed"), 0)
    tk.eq(foreign_writes(tk.command_calls()), 0)
  end,

  -- #5 integrity preflight: an EXPLICITLY unverified root cause blocks the PR even with a
  -- real upstream invite (the invite gate would otherwise pass).
  test_open_pr_refuses_when_root_cause_explicitly_unverified = function()
    tk.mock_command("gh issue view", {
      stdout = '{"assignees":[{"login":"gpeal"}],"comments":[]}',
    })
    local result = tk.run_department("departments/open_pr/main.lua", {
      queue = "codex_invited",
      payload = {
        schema = "codex-saga.invited.v1",
        dedup_key = DEDUP,
        source_ref = candidate_ref(),
        control_issue = "7",
        root_cause_verified = false,
      },
    })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_proposed"), 0)
  end,

  -- #5 fail-closed on the RECOVERED-INVITE path: the cron reconcile rebuilds codex_invited
  -- from markers and cannot carry root_cause_verified, so an ABSENT (nil) flag must block
  -- the PR just like an explicit false - otherwise an unverified candidate invited late
  -- could bypass the preflight (integrated Codex review P1).
  test_open_pr_refuses_when_root_cause_verified_absent = function()
    tk.mock_command("gh issue view", {
      stdout = '{"assignees":[{"login":"gpeal"}],"comments":[]}',
    })
    local result = tk.run_department("departments/open_pr/main.lua", {
      queue = "codex_invited",
      payload = {
        schema = "codex-saga.invited.v1",
        dedup_key = DEDUP,
        source_ref = candidate_ref(),
        control_issue = "7",
        -- root_cause_verified intentionally absent (nil), as on the recovery path
      },
    })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_proposed"), 0)
  end,

  -- ---- #16 invite-wait expiry -> disposition="ignored" ----------------------
  test_invite_wait_expired_pure = function()
    tk.eq(core.invite_wait_expired("2000-01-01T00:00:00Z"), true) -- long past the window
    tk.eq(core.invite_wait_expired("2999-01-01T00:00:00Z"), false) -- future creation
    tk.eq(core.invite_wait_expired(nil), false) -- unparseable -> fail-safe (no expiry)
  end,

  -- The cron tick expires an engaged candidate with no invite into a terminal IGNORED
  -- outcome: a durable disposition="ignored" record, NO codex_invited, ZERO foreign writes.
  test_invite_watch_tick_expires_to_ignored = function()
    local path = fresh_path("ignored")
    tk.mock_command("gh issue list", { stdout = engaged_list_stdout("2000-01-01T00:00:00Z") })
    tk.mock_command("gh issue view", { stdout = '{"assignees":[],"comments":[]}' })
    local result = tk.run_department("departments/invite_watch/main.lua", {
      queue = "codex_invite_watch_tick",
      payload = {},
    }, { env = { FKST_GITHUB_BOT_LOGIN = "codex-bot", FKST_LEARNING_OUTCOMES_PATH = path } })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_invited"), 0)
    tk.eq(foreign_writes(tk.command_calls()), 0)
    local rec = core.latest_outcome_by_dedup(core.read_outcomes({ path = path }))[DEDUP]
    tk.eq(rec.disposition, "ignored")
    tk.eq(rec.state, "needs_invite")
    tk.eq(rec.reason, "invite_wait_elapsed")
    tk.eq(rec.engagement_reaction, "none")
  end,

  -- Idempotent: a second tick over the same already-ignored candidate appends nothing new.
  test_invite_watch_tick_ignored_is_idempotent = function()
    local path = fresh_path("ignored-idem")
    tk.mock_command("gh issue list", { stdout = engaged_list_stdout("2000-01-01T00:00:00Z") })
    tk.mock_command("gh issue view", { stdout = '{"assignees":[],"comments":[]}' })
    local ev = { queue = "codex_invite_watch_tick", payload = {} }
    local env = { env = { FKST_GITHUB_BOT_LOGIN = "codex-bot", FKST_LEARNING_OUTCOMES_PATH = path } }
    tk.run_department("departments/invite_watch/main.lua", ev, env)
    tk.run_department("departments/invite_watch/main.lua", ev, env)
    local seen = 0
    for _, r in ipairs(core.read_outcomes({ path = path })) do
      if r.dedup_key == DEDUP and r.disposition == "ignored" then seen = seen + 1 end
    end
    tk.eq(seen, 1) -- exactly one ignored record despite two ticks
  end,

  -- Before the window elapses, a still-waiting candidate is NOT expired (no ignored record).
  test_invite_watch_tick_not_expired_keeps_waiting = function()
    local path = fresh_path("waiting")
    tk.mock_command("gh issue list", { stdout = engaged_list_stdout("2999-01-01T00:00:00Z") })
    tk.mock_command("gh issue view", { stdout = '{"assignees":[],"comments":[]}' })
    local result = tk.run_department("departments/invite_watch/main.lua", {
      queue = "codex_invite_watch_tick",
      payload = {},
    }, { env = { FKST_GITHUB_BOT_LOGIN = "codex-bot", FKST_LEARNING_OUTCOMES_PATH = path } })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_invited"), 0)
    tk.eq(core.latest_outcome_by_dedup(core.read_outcomes({ path = path }))[DEDUP], nil)
  end,

  -- ---- #12 outcome_watch broadened reconcile --------------------------------
  -- The reconcile scan queries ALL marker-bearing control issues by the STABLE candidate
  -- label across --state all (open+closed), not only currently-`engaged`-labeled ones.
  test_outcome_watch_reconcile_scans_all_candidate_issues = function()
    tk.mock_command("gh issue list", {
      stdout = '[{"number":7,"author":{"login":"codex-bot"},"body":"' .. json_escape(control_body(DEDUP, ORIGINAL_REF)) .. '"}]',
    })
    tk.mock_command("gh pr list", { stdout = "[]" })
    local result = tk.run_department("departments/outcome_watch/main.lua", {
      queue = "codex_outcome_watch_tick",
      payload = {},
    }, { env = { FKST_GITHUB_BOT_LOGIN = "codex-bot",
      FKST_LEARNING_OUTCOMES_PATH = fresh_path("reconcile") } })
    tk.eq(result.exit_code, 0)
    local saw_broadened = false
    for _, call in ipairs(tk.command_calls()) do
      local rendered = tostring(call.rendered or "")
      if rendered:find("issue list", 1, true) ~= nil
        and rendered:find("--label codex-saga:candidate", 1, true) ~= nil
        and rendered:find("--state all", 1, true) ~= nil then
        saw_broadened = true
      end
    end
    tk.is_true(saw_broadened)
  end,

  -- Reconcile does NOT over-claim an OPEN (still-in-flight) PR: derive stays "proposed",
  -- so no outcome is recovered and nothing is (mis)recorded as closed.
  test_outcome_watch_reconcile_skips_open_pr = function()
    tk.mock_command("gh issue list", {
      stdout = '[{"number":7,"author":{"login":"codex-bot"},"body":"' .. json_escape(control_body(DEDUP, ORIGINAL_REF)) .. '"}]',
    })
    tk.mock_command("gh pr list", {
      stdout = '[{"state":"OPEN","statusCheckRollup":[{"conclusion":"SUCCESS"}],"reviews":[],"comments":[]}]',
    })
    local result = tk.run_department("departments/outcome_watch/main.lua", {
      queue = "codex_outcome_watch_tick",
      payload = {},
    }, { env = { FKST_GITHUB_BOT_LOGIN = "codex-bot",
      FKST_LEARNING_OUTCOMES_PATH = fresh_path("open-pr") } })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_outcome_updated"), 0)
    tk.eq(foreign_writes(tk.command_calls()), 0)
  end,
}
