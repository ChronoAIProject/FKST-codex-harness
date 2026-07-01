-- core.invite: maintainer-invite re-derivation + volume-cap counting.
--
-- The invitation precondition (spec §10 gate3) is enforced by RE-DERIVING the
-- invite fact read-only from GitHub, never by trusting a payload flag. An invite is
-- a maintainer comment or assignment on the saga control issue. Fail-closed: an
-- invite we cannot positively confirm counts as "not invited".
local S = {}

-- The ~12 active codex team triagers who grant invitations (playbook §6). Logins
-- are matched case-insensitively and tolerate a GitHub App "[bot]" suffix.
local MAINTAINERS = {
  ["bolinfest"] = true,
  ["gpeal"] = true,
  ["pakrym-oai"] = true,
  ["etraut-openai"] = true,
  ["fcoury-oai"] = true,
  ["joeytrasatti-openai"] = true,
  ["easong-openai"] = true,
  ["dylan-hurd-oai"] = true,
  ["aibrahim-oai"] = true,
  ["jif-oai"] = true,
  ["ccy-oai"] = true,
  ["dedrisian-oai"] = true,
}

function S.install(M)
  function M.is_maintainer(login)
    if type(login) ~= "string" or login == "" then
      return false
    end
    local normalized = login:lower():gsub("%[bot%]$", "")
    return MAINTAINERS[normalized] == true
  end

  local function comment_login(comment)
    if type(comment) ~= "table" then
      return nil
    end
    if type(comment.author) == "table" then
      return comment.author.login
    end
    if type(comment.user) == "table" then
      return comment.user.login
    end
    return comment.author_login
  end

  -- Re-derive the invite fact from a fetched control-issue view (read-only).
  -- control_view = { assignees = {...}, comments = {...} } (the gh issue view JSON).
  function M.invite_in_view(control_view)
    if type(control_view) ~= "table" then
      return false
    end
    for _, assignee in ipairs(control_view.assignees or {}) do
      if type(assignee) == "table" and M.is_maintainer(assignee.login) then
        return true
      end
    end
    for _, comment in ipairs(control_view.comments or {}) do
      if M.is_maintainer(comment_login(comment)) then
        return true
      end
    end
    return false
  end

  -- Locate the control issue number for a candidate on the tracker by its control
  -- marker. control = { repo, number } or nil. Returns {repo, number} or nil.
  -- A carried locator is accepted, but the invite fact itself is always re-read.
  function M.locate_control_issue(dedup_key, carried_number, exec)
    local repo = M.tracker_repo()
    if M.is_nonempty_string(carried_number) or type(carried_number) == "number" then
      return { repo = repo, number = tostring(carried_number) }
    end
    -- Re-derive the locator by scanning open engaged control issues for the control
    -- marker. The marker is trusted ONLY when the control issue is bot-authored.
    local list = M.gh_read(M.gh_issue_list_argv(repo, M.state_label("engaged"), "number,body,author"), exec)
    if type(list) ~= "table" then
      return nil
    end
    local marker = M.control_marker(dedup_key)
    local bot = M.bot_login()
    for _, issue in ipairs(list) do
      if M.trusted_marker(issue, marker, bot) then
        return { repo = repo, number = tostring(issue.number) }
      end
    end
    return nil
  end

  -- The HARD precondition: positively confirm a recorded maintainer invite on the
  -- control issue. Returns false on any read failure (fail-closed).
  function M.recorded_invite(dedup_key, carried_number, exec)
    local control = M.locate_control_issue(dedup_key, carried_number, exec)
    if control == nil or control.number == nil then
      return false
    end
    local view = M.gh_read(M.gh_issue_view_argv(control.repo, control.number, "comments,assignees"), exec)
    if view == nil then
      return false
    end
    return M.invite_in_view(view)
  end

  -- Daily public-engagement volume cap (spec §10 gate4, default 3).
  function M.daily_cap()
    local raw = M.read_env("FKST_PROPOSE_DAILY_CAP")
    local n = tonumber(raw)
    if n == nil or n < 0 or n ~= math.floor(n) then
      return 3
    end
    return n
  end

  function M.today_utc()
    if type(os) == "table" and type(os.date) == "function" then
      local ok, d = pcall(os.date, "!%Y-%m-%d")
      if ok and type(d) == "string" then
        return d
      end
    end
    return "today"
  end

  function M.engagement_count_key()
    return "codex-saga/engage-count/" .. M.today_utc()
  end

  -- Within-runtime debounce fast-path only (NOT the authority across restarts).
  function M.todays_engagement_count()
    local raw = cache_get(M.engagement_count_key())
    return tonumber(raw) or 0
  end

  function M.record_engagement()
    local key = M.engagement_count_key()
    cache_set(key, tostring(M.todays_engagement_count() + 1))
  end

  -- DURABLE volume-cap truth: count today's trusted engagement records on the
  -- tracker. The engaged-label/today query is only the FETCH filter; an issue counts
  -- toward the cap ONLY when it is MARKER-TRUTH - bot-authored
  -- (author==FKST_GITHUB_BOT_LOGIN) AND its body carries the engagement (control)
  -- marker. A mislabeled or marker-less bot issue does NOT count, so the cap depends
  -- on marker truth, not query/label shape. Returns nil when the count cannot be
  -- determined (caller fails closed).
  function M.durable_engagement_count(exec)
    local list = M.gh_read(M.gh_engagement_list_argv(M.tracker_repo(), M.today_utc()), exec)
    if type(list) ~= "table" then
      return nil
    end
    local bot = M.bot_login()
    local count = 0
    for _, issue in ipairs(list) do
      local body = (type(issue) == "table") and issue.body or nil
      local dedup = M.control_dedup_from_body(body)
      if dedup ~= nil and M.trusted_marker(issue, M.control_marker(dedup), bot) then
        count = count + 1
      end
    end
    return count
  end

  -- The cap-check count: DURABLE truth is the authority (survives restarts); the
  -- runtime debounce can only raise it (to catch an in-burst engagement not yet
  -- visible on GitHub), never lower it. Returns nil when durable truth is unknown.
  function M.engagement_count(exec)
    local durable = M.durable_engagement_count(exec)
    if durable == nil then
      return nil
    end
    local cached = M.todays_engagement_count()
    if cached > durable then
      return cached
    end
    return durable
  end
end

return S
