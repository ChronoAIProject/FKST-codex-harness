-- core.markers: bot-authored GitHub marker builders.
--
-- These HTML-comment markers are the DURABLE saga truth (re-read after a real write
-- to confirm; trusted only when authored by FKST_GITHUB_BOT_LOGIN). They are CODE,
-- never locale catalog content (the i18n loader rejects `<!-- fkst:` tokens in
-- catalogs). once()/cache_* are only in-runtime debounce; the marker is the fact.
local S = {}

local DEDUP_LIMIT = 512

function S.install(M)
  local function assert_dedup(dedup_key)
    if not M.is_marker_safe(dedup_key, DEDUP_LIMIT) then
      error("codex-saga: invalid dedup_key for marker")
    end
  end

  -- Control issue identity marker (saga tracker on this harness repo).
  function M.control_marker(dedup_key)
    assert_dedup(dedup_key)
    return "<!-- fkst:codex-saga:control:" .. tostring(dedup_key) .. " -->"
  end

  -- Saga state marker on the control issue (version-ordered state mirror).
  function M.state_marker(dedup_key, state)
    assert_dedup(dedup_key)
    return '<!-- fkst:codex-saga:state:v1 dedup="' .. tostring(dedup_key)
      .. '" state="' .. tostring(state) .. '" -->'
  end

  -- Outward-post idempotency marker on the openai/codex candidate issue.
  function M.engage_marker(dedup_key)
    assert_dedup(dedup_key)
    return "<!-- fkst:codex-saga:engage:" .. tostring(dedup_key) .. " -->"
  end

  -- PR idempotency marker (carried in the PR body).
  function M.pr_marker(dedup_key)
    assert_dedup(dedup_key)
    return "<!-- fkst:codex-saga:open-pr:" .. tostring(dedup_key) .. " -->"
  end

  -- Outcome idempotency marker on the control issue: the durable record of OUR
  -- attempt outcome (learning-model §5), bot-authored, re-read for idempotency.
  function M.outcome_marker(dedup_key)
    assert_dedup(dedup_key)
    return "<!-- fkst:codex-saga:outcome:" .. tostring(dedup_key) .. " -->"
  end

  -- Source pointer marker on the control issue: a tiny pointer back to the ORIGINAL
  -- openai/codex candidate (ref only, NOT the body). Lets the invite path re-derive
  -- the original source_ref so downstream PR/CLA targeting never drifts to the
  -- control issue on the harness tracker.
  function M.source_marker(dedup_key, source_ref)
    assert_dedup(dedup_key)
    local ref = ""
    if type(source_ref) == "table" and type(source_ref.ref) == "string" then
      ref = source_ref.ref
    end
    if not M.is_marker_safe(ref, 200) then
      error("codex-saga: source_ref ref is not marker-safe")
    end
    return '<!-- fkst:codex-saga:source:v1 dedup="' .. tostring(dedup_key)
      .. '" ref="' .. ref .. '" -->'
  end

  -- Recover the ORIGINAL candidate source_ref from a control issue body's source
  -- marker (inverse of M.source_marker). Returns {kind="external", ref=...} or nil.
  function M.control_source_ref_from_body(body)
    if type(body) ~= "string" then
      return nil
    end
    local ref = body:match('<!%-%- fkst:codex%-saga:source:v1 dedup=".-" ref="(.-)" %-%->')
    if ref == nil or ref == "" then
      return nil
    end
    return { kind = "external", ref = ref }
  end

  -- ---- marker trust: a marker is durable truth ONLY when bot-authored ----------
  function M.author_login(entity)
    if type(entity) ~= "table" then
      return nil
    end
    if type(entity.author) == "table" then
      return entity.author.login
    end
    if type(entity.user) == "table" then
      return entity.user.login
    end
    return entity.author_login
  end

  -- Author == FKST_GITHUB_BOT_LOGIN (tolerating a GitHub App "[bot]" suffix + case).
  function M.bot_authored(entity, bot)
    if not M.is_nonempty_string(bot) then
      return false
    end
    local login = M.author_login(entity)
    if type(login) ~= "string" or login == "" then
      return false
    end
    local function norm(value)
      return value:lower():gsub("%[bot%]$", "")
    end
    return norm(login) == norm(tostring(bot))
  end

  function M.body_has_marker(entity, marker)
    return type(entity) == "table"
      and tostring(entity.body or ""):find(marker, 1, true) ~= nil
  end

  -- A marker is trusted ONLY when its text is present AND the entity is bot-authored.
  -- A foreign comment/body that merely contains the marker string is treated as
  -- ABSENT, so it cannot suppress a real write or distort saga state.
  function M.trusted_marker(entity, marker, bot)
    return M.body_has_marker(entity, marker) and M.bot_authored(entity, bot)
  end

  -- Program-produced saga UI-hint label for the control issue.
  function M.state_label(state)
    return "codex-saga:" .. tostring(state)
  end

  -- Recover the dedup_key from a control issue body's control marker (inverse of
  -- M.control_marker). Returns nil when the body carries no control marker.
  function M.control_dedup_from_body(body)
    if type(body) ~= "string" then
      return nil
    end
    return body:match("<!%-%- fkst:codex%-saga:control:(.-) %-%->")
  end
end

return S
