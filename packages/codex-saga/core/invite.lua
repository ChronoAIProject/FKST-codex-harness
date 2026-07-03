-- core.invite: maintainer-invite re-derivation on the UPSTREAM candidate thread +
-- volume-cap counting.
--
-- The invitation precondition (spec §10 gate3) is enforced by RE-DERIVING the invite
-- fact READ-ONLY from the UPSTREAM openai/codex issue where we engaged (the candidate
-- source_ref on FKST_CONTRIB_TARGET) - a maintainer REPLYING (or being assigned) there
-- is the real invite signal. It is NEVER trusted from a payload flag. Fail-closed: an
-- invite we cannot positively confirm counts as "not invited". Reading the upstream
-- thread is allowed under two-plane discipline (upstream = READ + gated-propose); no
-- foreign write ever happens here.
--
-- Maintainer identity has two signals, strongest first:
--   1. the comment authorAssociation (OWNER/MEMBER/COLLABORATOR) reported by GitHub -
--      public, needs no special permission, and is the primary "is a maintainer" fact;
--   2. a login allowlist FETCHED from the GitHub collaborators API when available;
--      a curated hardcoded list is the FALLBACK ONLY when the API is unavailable (our
--      bot has no push access to openai/codex, so the API call typically fails - the
--      fallback is the normal path, not the exception).
local S = {}

local GH = "gh"

-- GitHub author-associations that denote upstream write standing (a maintainer).
local MAINTAINER_ASSOCIATIONS = { OWNER = true, MEMBER = true, COLLABORATOR = true }

-- Fallback allowlist: the ~12 active codex team triagers who grant invitations
-- (playbook §6). Used ONLY when the collaborators API is unavailable. Logins are
-- matched case-insensitively and tolerate a GitHub App "[bot]" suffix.
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

-- Invite-wait deadline default (spec: invite_watch on_timeout="needs_invite", wall_clock
-- 720h). After this window elapses with no recorded invite, an engaged candidate is
-- treated as IGNORED (a real negative learning signal). Overridable via env.
local DEFAULT_INVITE_WAIT_HOURS = 720

function S.install(M)
  local function normalize_login(login)
    return login:lower():gsub("%[bot%]$", "")
  end

  -- is_maintainer(login[, allowlist]): login is present in the effective allowlist. The
  -- allowlist defaults to the hardcoded fallback set, preserving the single-arg contract
  -- (core.is_maintainer("Bolinfest") still works).
  function M.is_maintainer(login, allowlist)
    if type(login) ~= "string" or login == "" then
      return false
    end
    local set = (type(allowlist) == "table") and allowlist or MAINTAINERS
    return set[normalize_login(login)] == true
  end

  -- A GitHub author-association that denotes upstream write standing. This is the
  -- STRONGEST invite signal and needs no special API permission.
  function M.is_maintainer_association(association)
    if type(association) ~= "string" then
      return false
    end
    return MAINTAINER_ASSOCIATIONS[association:upper()] == true
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

  local function comment_association(comment)
    if type(comment) ~= "table" then
      return nil
    end
    return comment.authorAssociation or comment.author_association
  end

  -- gh api collaborators fetch (READ). Typed argv, program head only (no shell).
  function M.gh_collaborators_argv(repo)
    return {
      argv = { GH, "api", "repos/" .. tostring(repo) .. "/collaborators" },
      timeout = 30,
    }
  end

  -- Fetch the maintainer login allowlist from the GitHub collaborators API. Returns a
  -- normalized login set, or nil when the API is unavailable/empty (fail-closed to the
  -- fallback). READ-ONLY. NOTE: our bot usually lacks push access to openai/codex, so
  -- this call typically fails and the caller falls back to the curated list.
  function M.fetch_maintainer_logins(exec)
    local list = M.gh_read(M.gh_collaborators_argv(M.contrib_target()), exec)
    if type(list) ~= "table" then
      return nil
    end
    local set, n = {}, 0
    for _, collaborator in ipairs(list) do
      if type(collaborator) == "table" and type(collaborator.login) == "string"
        and collaborator.login ~= "" then
        set[normalize_login(collaborator.login)] = true
        n = n + 1
      end
    end
    if n == 0 then
      return nil
    end
    return set
  end

  -- The effective login allowlist: the API collaborators list WHEN AVAILABLE, else the
  -- curated hardcoded fallback. (The authorAssociation signal is independent and always
  -- available, so this only backstops login-based matching.)
  function M.resolve_maintainer_allowlist(exec)
    return M.fetch_maintainer_logins(exec) or MAINTAINERS
  end

  -- Re-derive the invite fact from a fetched UPSTREAM issue view (read-only). An invite is a
  -- maintainer RESPONSE that lands strictly AFTER our own engage comment on the thread (by
  -- authorAssociation or allowlisted login). PRE-EXISTING maintainer activity - an older
  -- comment, or an assignee - is NOT an invitation and must never launder into one: a
  -- maintainer who happened to comment before we engaged, or who self-assigned to work the
  -- issue, did not invite us, and opening an uninvited PR is a ban risk (playbook DON'T #1).
  -- Our engage comment is located by its bot-authored engage marker (dedup_key); gh returns
  -- comments chronologically, so a maintainer comment positioned AFTER ours is a genuine
  -- post-engagement response. Fail closed (no invite) when our own engage comment is not
  -- found. `allowlist` is the effective login set.
  function M.invite_in_upstream_view(view, allowlist, dedup_key)
    if type(view) ~= "table" or not M.is_nonempty_string(dedup_key) then
      return false
    end
    local bot = M.bot_login()
    local marker = M.engage_marker(dedup_key)
    local engaged = false
    for _, comment in ipairs(view.comments or {}) do
      if not engaged then
        if M.trusted_marker(comment, marker, bot) then
          engaged = true
        end
      elseif M.is_maintainer_comment(comment, allowlist) then
        return true
      end
    end
    return false
  end

  -- Whether a single upstream comment is a maintainer RESPONSE - by authorAssociation
  -- (MEMBER/OWNER/COLLABORATOR) or by an allowlisted login. Pure (no ordering); the
  -- post-engagement ordering is enforced by invite_in_upstream_view's caller-side scan.
  function M.is_maintainer_comment(comment, allowlist)
    return M.is_maintainer_association(comment_association(comment))
      or M.is_maintainer(comment_login(comment), allowlist)
  end

  -- The HARD precondition: positively confirm a recorded maintainer invite on the
  -- UPSTREAM openai/codex candidate thread (source_ref), NOT on our own tracker's control
  -- issue - maintainers reply upstream, not on the harness repo. Returns false on any
  -- read failure or unparseable source_ref (fail-closed). `allowlist` is optional; when a
  -- caller scanning many candidates has resolved it once, it is threaded to avoid a
  -- repeated collaborators API call. dedup_key is accepted for signature stability /
  -- logging; the invite fact is re-read from the upstream thread, never from the payload.
  function M.recorded_invite(dedup_key, source_ref, exec, allowlist)
    local candidate = M.parse_entity_ref(source_ref)
    if candidate == nil then
      return false
    end
    -- Two-plane HARD boundary: an invite is honored ONLY on the UPSTREAM contrib target
    -- (openai/codex). A source_ref pointing anywhere else - the fork, the tracker, or a
    -- stale/forged payload - can NEVER satisfy the invite gate, so maintainer standing on
    -- some OTHER repo (e.g. our own bot as OWNER/MEMBER of the fork) cannot be laundered
    -- into an upstream invite. Repo slugs compare case-insensitively.
    if candidate.repo:lower() ~= tostring(M.contrib_target()):lower() then
      return false
    end
    local view = M.gh_read(M.gh_issue_view_argv(candidate.repo, candidate.number, "comments,assignees"), exec)
    if view == nil then
      return false
    end
    allowlist = allowlist or M.resolve_maintainer_allowlist(exec)
    return M.invite_in_upstream_view(view, allowlist, dedup_key)
  end

  -- ---- invite-wait expiry (learning-model: the IGNORED terminal, #16) --------------
  -- The invite-wait window in seconds (default 720h; env override in whole hours).
  function M.invite_wait_seconds()
    local raw = M.read_env("FKST_INVITE_WAIT_HOURS")
    local n = tonumber(raw)
    if n == nil or n < 0 then
      n = DEFAULT_INVITE_WAIT_HOURS
    end
    return n * 3600
  end

  -- Current epoch seconds via the engine's portable `now()` seam (unix seconds), or nil.
  function M.now_epoch()
    if type(now) == "function" then
      local secs = tonumber(now())
      if secs ~= nil then
        return secs
      end
    end
    return nil
  end

  -- "2026-07-02T03:11:30Z" -> epoch seconds (UTC), or nil. os.time reads a table as LOCAL
  -- time, so the local-vs-UTC offset is derived at the parsed instant and added back.
  function M.iso8601_to_epoch(s)
    if type(s) ~= "string" then
      return nil
    end
    local y, mo, d, h, mi, sec = s:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
    if y == nil then
      return nil
    end
    if type(os) ~= "table" or type(os.time) ~= "function" or type(os.date) ~= "function" then
      return nil
    end
    local ok, epoch = pcall(function()
      local as_local = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(sec) })
      local offset = os.difftime(as_local, os.time(os.date("!*t", as_local)))
      return as_local + offset
    end)
    if not ok then
      return nil
    end
    return epoch
  end

  -- Has the invite-wait window elapsed since `created_at` (the control issue's creation
  -- time)? Fail-SAFE: returns false when either clock is unavailable or unparseable, so a
  -- missing clock NEVER force-expires a candidate into an IGNORED outcome.
  function M.invite_wait_expired(created_at)
    local created = M.iso8601_to_epoch(created_at)
    local now_s = M.now_epoch()
    if created == nil or now_s == nil then
      return false
    end
    return (now_s - created) > M.invite_wait_seconds()
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
