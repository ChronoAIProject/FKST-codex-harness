-- codex-triage shared logic (require-able as `core`).
--
-- The SELECTION SCORER + DEDUP (METHODOLOGY.md §3 rubrics, §5 the exact scoring
-- function, §7 dedup, §8 funnel order) is NOT implemented here: it lives ONCE in
-- the shared PURE library `libraries/rubric` (docs/learning-model.md §7 maps
-- "retrieve + score" to `codex-triage/score_dedup` + `rubric`). core re-exports
-- the rubric surface so departments + tests keep calling `core.score(...)` etc.,
-- while `codex-learn/relearn` scores against the SAME definition. There is one
-- implementation of the scorer.
--
-- What still lives here is package-local and NOT pure-scorer logic: the pipeline
-- failure wrap, and the PRODUCTION poll/read helpers (read_env, poll_open_issues,
-- load_clusters) - the only side-effecting code, never exercised by the test
-- suite (the department's act() takes an injectable seam so tests drive it with
-- inline fixtures).
--
-- Payload discipline (spec §6): events carry only {source_ref, schema,
-- dedup_key, score} - NEVER the issue body. Bodies are read back via source_ref.
local M = {}

-- The scorer's single implementation. PURE: no network/IO, so the tests that
-- call core.score / core.area_tier / core.attempt_candidates / ... exercise the
-- library directly through this delegation.
local rubric = require("rubric.score")

-- ---------------------------------------------------------------------------
-- pipeline failure wrap (workflow.saga `wrap` hook; fail-loud)
-- ---------------------------------------------------------------------------
-- Re-raise pipeline failures with the department name attached so the engine's
-- L1 fail-closed path gets a greppable, narrow error_class (not a bare error).
function M.wrap_pipeline_failure(name, fn)
  return function(event)
    local ok, result = pcall(fn, event)
    if not ok then
      error(string.format("codex-triage/%s pipeline failure: %s", name, tostring(result)))
    end
    return result
  end
end

-- ---------------------------------------------------------------------------
-- Scorer + dedup re-export (single implementation in libraries/rubric).
-- METHODOLOGY §3 (area tiers) / §5 (score, hard drops, bins) / §7 (dedup) / §8
-- (attempt funnel order). Callers use core.* exactly as before.
-- ---------------------------------------------------------------------------
M.normalize_labels = rubric.normalize_labels
M.area_tier = rubric.area_tier
M.type_bonus = rubric.type_bonus
M.anatomy = rubric.anatomy
M.demand = rubric.demand
M.classify = rubric.classify
M.score = rubric.score
M.cluster_index = rubric.cluster_index
M.dedup_key = rubric.dedup_key
M.is_cluster_representative = rubric.is_cluster_representative
M.candidate_source_ref = rubric.candidate_source_ref
M.candidate_payload = rubric.candidate_payload
M.attempt_candidates = rubric.attempt_candidates

-- ---------------------------------------------------------------------------
-- PRODUCTION side-effecting helpers (never exercised by tests; the department
-- takes an injectable seam so the suite drives it with inline fixtures).
-- ---------------------------------------------------------------------------

-- read_env: PREFER the portable `os.getenv` seam (the pattern codex-saga + codex-learn
-- use; the engine loads the full os lib) so triage runs cross-platform. Fall back to a
-- `printf` shell read ONLY where os.getenv is unavailable. Fails soft to nil.
function M.read_env(name)
  if type(os) == "table" and type(os.getenv) == "function" then
    local raw = os.getenv(name)
    if raw == nil then
      return nil
    end
    local s = M.trim(raw)
    if s == "" then
      return nil
    end
    return s
  end
  if type(exec_sync) ~= "function" then
    return nil
  end
  local ok, result = pcall(exec_sync, 'printf %s "$' .. tostring(name) .. '"')
  if ok and type(result) == "table" and tonumber(result.exit_code) == 0 then
    local value = result.stdout
    if type(value) == "string" and value ~= "" then
      return M.trim(value)
    end
  end
  return nil
end

-- contrib_target: the foreign read target (FKST_CONTRIB_TARGET), default openai/codex.
function M.contrib_target()
  return M.read_env("FKST_CONTRIB_TARGET") or "openai/codex"
end

-- normalize_issue_pages: flatten `gh api --paginate --slurp` page arrays into the
-- pure {number,title,body,labels,reactions} issue shape, dropping PRs.
function M.normalize_issue_pages(stdout)
  local issues = {}
  if type(stdout) ~= "string" or stdout == "" then
    return issues
  end
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    return issues
  end
  local ok, pages = pcall(json.decode, stdout)
  if not ok or type(pages) ~= "table" then
    return issues
  end
  for _, page in ipairs(pages) do
    if type(page) == "table" then
      for _, raw in ipairs(page) do
        if type(raw) == "table" and raw.pull_request == nil then
          local labels = {}
          if type(raw.labels) == "table" then
            for _, label in ipairs(raw.labels) do
              if type(label) == "table" and type(label.name) == "string" then
                table.insert(labels, label.name)
              elseif type(label) == "string" then
                table.insert(labels, label)
              end
            end
          end
          local reactions = 0
          if type(raw.reactions) == "table" then
            reactions = tonumber(raw.reactions.total_count) or 0
          end
          table.insert(issues, {
            number = raw.number,
            title = raw.title,
            body = raw.body or "",
            labels = labels,
            reactions = reactions,
          })
        end
      end
    end
  end
  return issues
end

-- poll_open_issues: read-only `gh` poll of the contrib target's open issues.
-- All gh egress goes through the argv adapter (exec_argv), never a raw command head.
function M.poll_open_issues(repo)
  if type(exec_argv) ~= "function" then
    error("codex-triage: issue poll requires exec_argv")
  end
  -- The full paginated poll of a large open-issue set can exceed a fixed 120s budget
  -- (openai/codex passed 8k+ open issues ~ 48MB, ~126s), which would time the poll out
  -- and raise no candidate. Make the budget configurable so a growing target does not
  -- stall discovery. Default 300s (headroom over ~126s, within the 5m poll cadence);
  -- override FKST_TRIAGE_POLL_TIMEOUT. NOTE: fetching every open issue each tick is the
  -- deeper scaling limit - prefer an incremental (updated-since) poll as issues grow.
  local poll_timeout = tonumber(M.read_env("FKST_TRIAGE_POLL_TIMEOUT")) or 300
  local endpoint = string.format("repos/%s/issues?state=open&per_page=100", repo)
  local result = exec_argv({ argv = { "gh", "api", "--paginate", "--slurp", endpoint }, timeout = poll_timeout })
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    error("codex-triage: gh issue poll failed for " .. tostring(repo))
  end
  return M.normalize_issue_pages(result.stdout)
end

-- load_clusters: read the seed cluster corpus (data/open_issue_clusters.json) by
-- source_ref, never inlined. Fails soft to {} (degrades to no-dedup) so a missing
-- file never crashes the poll.
function M.load_clusters()
  if type(file) ~= "table" or type(file.read) ~= "function" then
    return {}
  end
  local path = M.read_env("FKST_TRIAGE_CLUSTERS_PATH") or "data/open_issue_clusters.json"
  local ok, text = pcall(function()
    return file.read(path)
  end)
  if not ok or type(text) ~= "string" or text == "" then
    return {}
  end
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    return {}
  end
  local ok2, parsed = pcall(json.decode, text)
  if not ok2 or type(parsed) ~= "table" then
    return {}
  end
  return parsed
end

-- ---------------------------------------------------------------------------
-- issue MIRROR (read-only). The mirror is produced OUT-OF-BAND by
-- scripts/reconcile_issues.py, which owns all pagination/checkpoint/watermark
-- state. codex-triage is a `stateless_adapter`: it only READS the mirror + the
-- freshness stamp; it NEVER advances or repairs reconcile state.
-- ---------------------------------------------------------------------------
function M.mirror_path()
  local root = M.read_env("FKST_DURABLE_ROOT") or ".fkst/durable"
  return root .. "/codex-issue-mirror/open_issues.compact.jsonl"
end

function M.mirror_state_path()
  local root = M.read_env("FKST_DURABLE_ROOT") or ".fkst/durable"
  return root .. "/codex-issue-mirror/reconcile_state.json"
end

-- Read the cached compact open-issue mirror (JSONL, one issue per line). Returns the
-- issue array, or NIL when the mirror is absent/unreadable (so score_dedup can fail
-- closed instead of doing an in-tick live pull). Never inlines bodies (the mirror
-- carries only the small model the producer wrote).
function M.load_cached_open_issues(opts)
  opts = opts or {}
  local path = opts.path or M.mirror_path()
  if type(file) ~= "table" or type(file.read) ~= "function" then
    return nil
  end
  if type(file.exists) == "function" and not file.exists(path) then
    return nil
  end
  local ok, text = pcall(file.read, path)
  if not ok or type(text) ~= "string" or text == "" then
    return nil
  end
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    return nil
  end
  local issues = {}
  for line in text:gmatch("[^\n]+") do
    local ok2, rec = pcall(json.decode, line)
    if ok2 and type(rec) == "table" then
      issues[#issues + 1] = rec
    end
  end
  return issues
end

-- The producer's reconcile_state.json (freshness stamp + `partial` flag + count), or nil
-- when absent/unreadable. score_dedup fails closed unless this carries a valid, non-partial
-- fresh_as_of_epoch within the age budget.
function M.mirror_state(opts)
  opts = opts or {}
  local path = opts.path or M.mirror_state_path()
  if type(file) ~= "table" or type(file.read) ~= "function" then
    return nil
  end
  if type(file.exists) == "function" and not file.exists(path) then
    return nil
  end
  local ok, text = pcall(file.read, path)
  if not ok or type(text) ~= "string" or text == "" then
    return nil
  end
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    return nil
  end
  local ok2, parsed = pcall(json.decode, text)
  if not ok2 or type(parsed) ~= "table" then
    return nil
  end
  return parsed
end

-- Current epoch seconds via the engine's portable `now()` seam (sdk_basic; unix seconds) -
-- the SAME clock codex-learn uses. PLATFORM-AGNOSTIC + deterministic: NEVER a `date +%s`
-- shell-out (Unix-only) and NEVER os.time (non-deterministic, discouraged in the engine model).
function M.now_epoch()
  if type(now) == "function" then
    local secs = tonumber(now())
    if secs ~= nil then
      return secs
    end
  end
  return nil
end

-- Trim helper (bounded) - mirrors the shared predicate without importing it.
function M.trim(value)
  if value == nil then
    return nil
  end
  return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ---------------------------------------------------------------------------
-- STRICT single-flight guard over the saga's durable outcome channel.
--
-- codex-triage is otherwise stateless, but a live "one issue at a time" run needs
-- discovery to respect the saga control plane: do not raise another candidate while
-- the latest outcome for any candidate is still non-final, and do not re-raise a
-- candidate that already has a final local verdict.
-- ---------------------------------------------------------------------------
function M.triage_single_flight_enabled()
  return M.read_env("FKST_TRIAGE_SINGLE_FLIGHT") == "1"
end

function M.triage_outcomes_path()
  local override = M.read_env("FKST_TRIAGE_OUTCOMES_PATH") or M.read_env("FKST_LEARNING_OUTCOMES_PATH")
  if override ~= nil then
    return override
  end
  local root = M.read_env("FKST_DURABLE_ROOT") or ".fkst/durable"
  return root .. "/codex-saga/outcomes.jsonl"
end

function M.read_saga_outcomes(opts)
  opts = opts or {}
  local path = opts.path or M.triage_outcomes_path()
  if type(file) ~= "table" or type(file.read) ~= "function" then
    return {}
  end
  if type(file.exists) == "function" and not file.exists(path) then
    return {}
  end
  local ok, text = pcall(file.read, path)
  if not ok or type(text) ~= "string" or text == "" then
    return {}
  end
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    return {}
  end
  local records = {}
  for line in text:gmatch("[^\n]+") do
    local trimmed = M.trim(line)
    if trimmed ~= nil and trimmed ~= "" then
      local ok2, rec = pcall(json.decode, trimmed)
      if ok2 and type(rec) == "table" then
        records[#records + 1] = rec
      end
    end
  end
  return records
end

function M.latest_saga_outcomes(records)
  local latest = {}
  for _, rec in ipairs(records or {}) do
    if type(rec) == "table" and type(rec.dedup_key) == "string" and rec.dedup_key ~= "" then
      latest[rec.dedup_key] = rec
    end
  end
  return latest
end

function M.outcome_is_final(rec)
  if type(rec) ~= "table" then
    return false
  end
  local disposition = tostring(rec.disposition or "")
  local state = tostring(rec.state or "")

  if disposition == "dropped" or disposition == "merged" or disposition == "closed"
    or disposition == "ignored" or disposition == "proposed" then
    return true
  end
  if disposition:find("^refused", 1, false) ~= nil then
    return true
  end
  if state == "needs_info" or state == "blocked" or state == "refused"
    or state == "security_routed" or state == "needs_invite" or state == "tracked" then
    return true
  end
  return false
end

function M.active_saga_candidate(latest)
  for dedup_key, rec in pairs(latest or {}) do
    if not M.outcome_is_final(rec) then
      return dedup_key, rec
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- REMOTE claims: the saga control issues on the harness tracker are the
-- CROSS-SUBSTRATE claim ledger. Local outcomes.jsonl only knows what THIS
-- machine did; when several substrates run against the same contrib target,
-- an open control issue (created by codex-saga at diagnose-adopt) is the
-- shared "this candidate is claimed" fact. Read-only; real posture only
-- (FKST_GITHUB_WRITE=1) so hermetic tests never exec a command; FAIL-CLOSED:
-- an unreadable tracker scan in live posture raises NO candidates this tick
-- (never double-claim on a blind tick - the next tick retries).
-- ---------------------------------------------------------------------------
function M.tracker_repo()
  return M.read_env("FKST_SAGA_TRACKER_REPO") or "ChronoAIProject/FKST-codex-harness"
end

function M.remote_claims_enabled()
  return M.read_env("FKST_GITHUB_WRITE") == "1"
end

-- Terminal board-label suffixes: the claim is settled (a re-raise is pointless, not
-- unsafe). MIRRORS codex-saga's STATE_PHASE_LABEL terminal tags (core/progress.lua) -
-- change them together.
local REMOTE_FINAL_STAGES = {
  ["needs-info"] = true, rejected = true, tracked = true, merged = true, closed = true,
  blocked = true, ["security-routed"] = true, ["needs-invite"] = true,
}

-- Parse one tracker issue (gh JSON row) into (dedup_key, stage). The control marker
-- carries the dedup_key; the swapped codex-saga:<phase|terminal> label carries the
-- current stage. Sticky locators (candidate/engaged) and prio-* tags are NOT stages -
-- engaged counts as a stage only when no swappable phase label is present.
function M.claim_from_issue(issue)
  if type(issue) ~= "table" or type(issue.body) ~= "string" then
    return nil
  end
  local dedup = issue.body:match("<!%-%- fkst:codex%-saga:control:(.-) %-%->")
  if dedup == nil or dedup == "" then
    return nil
  end
  local stage = nil
  for _, label in ipairs(issue.labels or {}) do
    local name = type(label) == "table" and tostring(label.name or "") or tostring(label)
    local suffix = name:match("^codex%-saga:(.+)$")
    if suffix ~= nil and suffix ~= "candidate" and suffix:find("^prio%-") == nil then
      if suffix ~= "engaged" then
        stage = suffix -- the swappable phase/terminal label wins
      elseif stage == nil then
        stage = "engaged" -- sticky engaged only as a fallback stage
      end
    end
  end
  return dedup, stage or "claimed"
end

-- Claim lease TTL: a NON-final claim whose control issue has not been touched for this
-- many seconds is STALE - its substrate is presumed dead and the claim is released
-- (dropped from the ledger view) so the loop cannot deadlock on a crashed peer. Every
-- progress comment / label swap bumps GitHub's updatedAt, so a live substrate's claim
-- keeps renewing itself. Final claims never expire.
function M.claim_ttl_seconds()
  local n = tonumber(M.read_env("FKST_CLAIM_TTL_SECONDS"))
  if n == nil or n <= 0 then
    return 3600
  end
  return n
end

-- "2026-07-02T03:11:30Z" -> epoch seconds (UTC), or nil. os.time interprets a table as
-- LOCAL time, so the local-vs-UTC offset is re-derived and added back.
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
    -- Local-vs-UTC offset derived AT the parsed instant (not at now), so a timestamp
    -- from the other DST season is not shifted by an hour.
    local offset = os.difftime(as_local, os.time(os.date("!*t", as_local)))
    return as_local + offset
  end)
  if not ok then
    return nil
  end
  return epoch
end

-- The gh scan page size; a result AT the cap means the ledger view may be TRUNCATED,
-- which must read as "unreadable" (fail closed), never as a silently partial ledger.
local REMOTE_SCAN_LIMIT = 1000

-- Scan the tracker's OPEN control issues -> { [dedup_key] = stage }. Returns nil when
-- the scan cannot be read OR may be truncated (caller fails closed in live posture).
-- STALE non-final claims (lease expired; see claim_ttl_seconds) are RELEASED - omitted
-- from the view - so a dead substrate cannot block the fleet; an unparseable updatedAt
-- counts as FRESH (fail toward blocking). The scan trusts any author: the tracker is
-- the OWNED private repo and a colleague's substrate may run under a different bot login.
function M.read_remote_claims(exec)
  local run = exec or exec_argv
  if type(run) ~= "function" then
    return nil
  end
  local ok, out = pcall(run, {
    argv = { "gh", "issue", "list", "--repo", M.tracker_repo(), "--label", "codex-saga:candidate",
      "--state", "open", "--limit", tostring(REMOTE_SCAN_LIMIT), "--json", "number,body,labels,updatedAt" },
    timeout = 30,
  })
  if not ok or type(out) ~= "table" or out.exit_code ~= 0 then
    return nil
  end
  local ok2, list = pcall(json.decode, out.stdout or "")
  if not ok2 or type(list) ~= "table" then
    return nil
  end
  if #list >= REMOTE_SCAN_LIMIT then
    return nil -- possibly truncated: a partial ledger must fail closed, not mislead
  end
  local now = M.now_epoch()
  local ttl = M.claim_ttl_seconds()
  local claims = {}
  for _, issue in ipairs(list) do
    local dedup, stage = M.claim_from_issue(issue)
    if dedup ~= nil then
      local stale = false
      if not M.remote_claim_is_final(stage) and now ~= nil then
        local touched = M.iso8601_to_epoch(type(issue) == "table" and issue.updatedAt or nil)
        if touched ~= nil and (now - touched) > ttl then
          stale = true
          log.info("codex-triage: releasing stale remote claim " .. tostring(dedup)
            .. " (stage=" .. tostring(stage) .. ", idle>" .. tostring(ttl) .. "s)")
        end
      end
      if not stale then
        claims[dedup] = stage
      end
    end
  end
  return claims
end

function M.remote_claim_is_final(stage)
  return REMOTE_FINAL_STAGES[tostring(stage or "")] == true
end

-- The first remotely-claimed candidate still IN FLIGHT (non-final stage), if any.
function M.active_remote_claim(claims)
  for dedup_key, stage in pairs(claims or {}) do
    if not M.remote_claim_is_final(stage) then
      return dedup_key, stage
    end
  end
  return nil
end

return M
