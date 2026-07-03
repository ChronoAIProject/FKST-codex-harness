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
-- issue MIRROR (read side). The mirror has TWO interchangeable producers that
-- share one checkpoint layout: scripts/reconcile_issues.py (out-of-band host
-- cron/manual - the fast path) and the in-package SLOW bootstrap below (a few
-- pages per tick, for runs with no host cron - e.g. a hosted session pod).
-- These read helpers stay producer-agnostic: they only READ the mirror + the
-- freshness stamp and never repair either producer's state.
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

-- ---------------------------------------------------------------------------
-- mirror BOOTSTRAP (the in-package SLOW pull). When the mirror is absent or
-- unusable, score_dedup advances THIS bootstrap a few bounded pages per tick
-- instead of idling forever on "run scripts/reconcile_issues.py" (a hosted
-- pod-per-session run has no out-of-band host cron, so the package must be able
-- to refuel itself). Discipline:
--   * SLOW BY DESIGN: at most FKST_TRIAGE_BOOTSTRAP_PAGES (default 3) pages per
--     tick, and a page is only STARTED while elapsed + page-timeout fits inside
--     FKST_TRIAGE_BOOTSTRAP_BUDGET (default 20s) - provably inside the
--     department's 30s stall window. The 126s all-or-nothing poll still NEVER
--     runs in-tick.
--   * Checkpoint layout is IDENTICAL to scripts/reconcile_issues.py
--     (checkpoint/page-%04d.jsonl) so either producer can run against the same
--     durable root; the Lua side keeps its resume cursor in
--     checkpoint/bootstrap_cursor.json (the python side globs page files, so the
--     cursor is invisible to it). Concurrent producers are tolerated: page
--     writes are idempotent by page number and the combine step dedupes.
--   * Same COMPACT projection + validate-before-swap + atomic rename as the
--     script: a malformed/degenerate checkpoint can never replace a last-good
--     mirror (it resets and the pull restarts from page 1).
--   * Candidates stay FAIL-CLOSED while bootstrapping: score_dedup raises
--     NOTHING until a complete, fresh, non-partial mirror exists.
-- Kill switch: FKST_TRIAGE_BOOTSTRAP=0 restores the pure fail-closed posture.
-- ---------------------------------------------------------------------------

local BOOTSTRAP_PER_PAGE = 100
local BOOTSTRAP_BODY_EXCERPT = 1000 -- MUST match scripts/reconcile_issues.py BODY_EXCERPT
local BOOTSTRAP_MIN_EXPECTED = 50 -- matches the script's --min-expected default
local BOOTSTRAP_MAX_EXPECTED = 200000

function M.bootstrap_enabled()
  return M.read_env("FKST_TRIAGE_BOOTSTRAP") ~= "0"
end

local function bootstrap_root(opts)
  return (opts and opts.root) or M.read_env("FKST_DURABLE_ROOT") or ".fkst/durable"
end

function M.mirror_checkpoint_dir(root)
  return tostring(root or bootstrap_root(nil)) .. "/codex-issue-mirror/checkpoint"
end

function M.bootstrap_cursor_path(root)
  return M.mirror_checkpoint_dir(root) .. "/bootstrap_cursor.json"
end

local function bootstrap_page_path(ckpt_dir, page)
  return string.format("%s/page-%04d.jsonl", ckpt_dir, page)
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- file.write cannot create directories; mkdir -p via the Lua stdlib (same
-- pattern as codex-learn/core/io.lua). Best-effort + idempotent.
local function ensure_dir(dir)
  if type(os) == "table" and type(os.execute) == "function" then
    pcall(os.execute, "mkdir -p " .. shell_quote(dir))
  end
end

local function json_escape_string(value)
  local s = tostring(value):gsub('[%c\\"]', function(c)
    if c == "\\" then return "\\\\" end
    if c == '"' then return '\\"' end
    if c == "\n" then return "\\n" end
    if c == "\r" then return "\\r" end
    if c == "\t" then return "\\t" end
    return string.format("\\u%04x", string.byte(c))
  end)
  return '"' .. s .. '"'
end

-- utf8_bounded_prefix: truncate `s` to at most `max_bytes` bytes WITHOUT splitting
-- a multi-byte UTF-8 character. Lua string.sub cuts on BYTE offsets, so a naive
-- body:sub(1, N) can slice through a codepoint and leave an invalid trailing
-- sequence. The engine's file.write is UTF-8-only (Lua string -> Rust String) and
-- rejects the WHOLE page on the first invalid byte, so the mirror checkpoint could
-- never persist and the bootstrap looped forever raising no candidates. Trimming
-- back to the last complete character keeps the excerpt valid UTF-8 and still
-- within the byte budget the readback validation caps (2 * BOOTSTRAP_BODY_EXCERPT).
local function utf8_bounded_prefix(s, max_bytes)
  if #s <= max_bytes then
    return s
  end
  local cut = max_bytes
  -- Continuation bytes are 0x80..0xBF; if the byte just past the cut is one, the
  -- cut landed inside a character - walk back to that character's lead byte.
  while cut > 0 do
    local nxt = string.byte(s, cut + 1)
    if nxt == nil or nxt < 0x80 or nxt >= 0xC0 then
      break
    end
    cut = cut - 1
  end
  return string.sub(s, 1, cut)
end

-- compact_issue: Lua port of the script's compact() projection - the SMALL model
-- with a BOUNDED body excerpt (the rubric's anatomy score reads body[:600]).
-- PR rows are excluded by the caller (bootstrap_fetch_page).
function M.compact_issue(raw, repo)
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
  local body = raw.body
  if type(body) ~= "string" then
    body = ""
  end
  local reactions = 0
  if type(raw.reactions) == "table" then
    reactions = tonumber(raw.reactions.total_count) or 0
  end
  return {
    number = raw.number,
    title = type(raw.title) == "string" and raw.title or "",
    body = utf8_bounded_prefix(body, BOOTSTRAP_BODY_EXCERPT),
    labels = labels,
    reactions = reactions,
    updated_at = type(raw.updated_at) == "string" and raw.updated_at or nil,
    source_ref = { kind = "external", ref = tostring(repo) .. "#issues/" .. tostring(raw.number) },
  }
end

-- The SDK is decode-only (JSON is the engine wire boundary), so the bootstrap
-- owns a tiny encoder for its FIXED shapes - same approach as
-- codex-saga/core/outcomes_store.lua. Key order is fixed for stable lines.
local function encode_compact_issue(rec)
  local labels = {}
  for _, l in ipairs(rec.labels or {}) do
    table.insert(labels, json_escape_string(l))
  end
  return "{"
    .. '"number":' .. tostring(tonumber(rec.number) or 0)
    .. ',"title":' .. json_escape_string(rec.title or "")
    .. ',"body":' .. json_escape_string(rec.body or "")
    .. ',"labels":[' .. table.concat(labels, ",") .. "]"
    .. ',"reactions":' .. tostring(tonumber(rec.reactions) or 0)
    .. ',"updated_at":' .. (rec.updated_at ~= nil and json_escape_string(rec.updated_at) or "null")
    .. ',"source_ref":{"kind":"external","ref":' .. json_escape_string((rec.source_ref or {}).ref or "") .. "}"
    .. "}"
end

function M.read_bootstrap_cursor(opts)
  local path = M.bootstrap_cursor_path(bootstrap_root(opts))
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
  local next_page = tonumber(parsed.next_page)
  if next_page == nil or next_page < 1 then
    return nil
  end
  return { next_page = math.floor(next_page), started_epoch = tonumber(parsed.started_epoch) }
end

function M.write_bootstrap_cursor(cursor, opts)
  local ckpt = M.mirror_checkpoint_dir(bootstrap_root(opts))
  ensure_dir(ckpt)
  local line = '{"next_page":' .. tostring(tonumber(cursor.next_page) or 1)
    .. ',"started_epoch":' .. tostring(tonumber(cursor.started_epoch) or "null") .. "}"
  local ok = pcall(file.write, M.bootstrap_cursor_path(bootstrap_root(opts)), line)
  return ok
end

-- reset_bootstrap: drop the cursor + every checkpointed page below it so the
-- next tick restarts the pull from page 1 (self-healing after a corrupt or
-- expired checkpoint). Best-effort; os.remove failures are ignored.
function M.reset_bootstrap(cursor, opts)
  local ckpt = M.mirror_checkpoint_dir(bootstrap_root(opts))
  local last_page = (tonumber(cursor and cursor.next_page) or 1) - 1
  if type(os) == "table" and type(os.remove) == "function" then
    for page = 1, last_page do
      pcall(os.remove, bootstrap_page_path(ckpt, page))
    end
    pcall(os.remove, M.bootstrap_cursor_path(bootstrap_root(opts)))
  end
end

-- bootstrap_fetch_page: fetch ONE page of open issues (argv adapter, injectable
-- for tests). Returns (rows, is_end, err): rows=nil on a transient failure (the
-- caller retries the SAME page next tick), is_end=true past the last page.
function M.bootstrap_fetch_page(repo, page, opts)
  opts = opts or {}
  local run = opts.exec
  if run == nil and type(exec_argv) == "function" then
    run = exec_argv
  end
  if run == nil then
    return nil, false, "no exec adapter"
  end
  local timeout = tonumber(M.read_env("FKST_TRIAGE_BOOTSTRAP_PAGE_TIMEOUT")) or 15
  local endpoint = string.format(
    "repos/%s/issues?state=open&per_page=%d&page=%d&sort=created&direction=asc",
    tostring(repo), BOOTSTRAP_PER_PAGE, page)
  local ok, result = pcall(run, { argv = { "gh", "api", endpoint }, timeout = timeout })
  if not ok or type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    local err = "page fetch failed"
    if type(result) == "table" and result.stderr ~= nil then
      err = tostring(result.stderr):sub(1, 200)
    elseif not ok then
      err = tostring(result):sub(1, 200)
    end
    return nil, false, err
  end
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    return nil, false, "no json decoder"
  end
  local ok2, raw = pcall(json.decode, result.stdout)
  if not ok2 or type(raw) ~= "table" then
    return nil, false, "unparseable page json"
  end
  if #raw == 0 then
    return {}, true, nil -- past the last page
  end
  local rows = {}
  for _, item in ipairs(raw) do
    -- PRs come back on the issues endpoint - exclude them (same as the script).
    if type(item) == "table" and item.pull_request == nil and item.number ~= nil then
      table.insert(rows, M.compact_issue(item, repo))
    end
  end
  return rows, false, nil
end

-- finalize_bootstrap: combine checkpointed pages 1..next_page-1 IN ORDER,
-- re-validate EVERY line (the checkpoint may come from an older run or from the
-- python producer), dedupe pagination-drift duplicates by issue number (last
-- occurrence wins, first-seen order), and only then swap the live mirror +
-- freshness state. Returns (count) or (nil, reason) WITHOUT touching the
-- last-good mirror.
function M.finalize_bootstrap(cursor, opts)
  opts = opts or {}
  local clock = opts.clock or M.now_epoch
  local now_s = clock()
  if now_s == nil then
    -- without a readable clock the state stamp would be permanently unusable
    -- (score_dedup rejects a stamp-less mirror) - never swap blind.
    return nil, "clock unavailable"
  end
  local root = bootstrap_root(opts)
  local ckpt = M.mirror_checkpoint_dir(root)
  local last_page = (tonumber(cursor.next_page) or 1) - 1
  local min_expected = tonumber(opts.min_expected) or BOOTSTRAP_MIN_EXPECTED
  local order, dedup = {}, {}
  for page = 1, last_page do
    local ok, text = pcall(file.read, bootstrap_page_path(ckpt, page))
    if not ok or type(text) ~= "string" then
      return nil, "missing checkpoint page " .. page
    end
    for line in text:gmatch("[^\n]+") do
      local ok2, rec = pcall(json.decode, line)
      if not ok2 or type(rec) ~= "table" or rec.number == nil
        or type(rec.source_ref) ~= "table" or rec.source_ref.ref == nil then
        return nil, "malformed checkpoint line (page " .. page .. ")"
      end
      if type(rec.body) == "string" and #rec.body > 2 * BOOTSTRAP_BODY_EXCERPT then
        return nil, "body excerpt too large (page " .. page .. ")"
      end
      if dedup[rec.number] == nil then
        table.insert(order, rec.number)
      end
      dedup[rec.number] = line
    end
  end
  local count = #order
  if count < min_expected then
    return nil, string.format("%d issues < min %d", count, min_expected)
  end
  if count > BOOTSTRAP_MAX_EXPECTED then
    return nil, string.format("%d issues > max %d", count, BOOTSTRAP_MAX_EXPECTED)
  end
  local lines = {}
  for _, num in ipairs(order) do
    table.insert(lines, dedup[num])
  end
  local model = root .. "/codex-issue-mirror/open_issues.compact.jsonl"
  local body = table.concat(lines, "\n") .. "\n"
  local tmp = model .. ".tmp"
  local ok_tmp = pcall(file.write, tmp, body)
  if not ok_tmp then
    return nil, "tmp write failed"
  end
  local renamed = false
  if type(os) == "table" and type(os.rename) == "function" then
    local ok_mv, res = pcall(os.rename, tmp, model)
    renamed = ok_mv and res == true
  end
  if not renamed then
    -- fallback: direct write of the ALREADY-validated content (non-atomic).
    local ok_direct = pcall(file.write, model, body)
    if not ok_direct then
      return nil, "mirror write failed"
    end
    if type(os) == "table" and type(os.remove) == "function" then
      pcall(os.remove, tmp)
    end
  end
  local iso = ""
  if type(os) == "table" and type(os.date) == "function" then
    local ok_date, formatted = pcall(os.date, "!%Y-%m-%dT%H:%M:%SZ", now_s)
    if ok_date and type(formatted) == "string" then
      iso = formatted
    end
  end
  local started = tonumber(cursor.started_epoch)
  local state_line = '{"model_version":"issue-mirror.v1"'
    .. ',"source_repo":' .. json_escape_string(opts.repo or M.contrib_target())
    .. ',"count":' .. tostring(count)
    .. ',"fresh_as_of_epoch":' .. tostring(math.floor(now_s))
    .. ',"fresh_as_of":' .. json_escape_string(iso)
    .. ',"reconcile_seconds":' .. tostring(started ~= nil and math.floor(now_s - started) or 0)
    .. ',"partial":false'
    .. ',"producer":"codex-triage.bootstrap"}'
  local ok_state = pcall(file.write, root .. "/codex-issue-mirror/reconcile_state.json", state_line)
  if not ok_state then
    return nil, "state write failed"
  end
  M.reset_bootstrap(cursor, opts) -- success: clear the checkpoint + cursor
  return count
end

-- bootstrap_advance: one tick's paced slice of the pull. Resumes the persisted
-- cursor (restarting a pull whose START is older than the mirror freshness
-- budget, so days-old pages never splice into a "fresh" mirror), fetches up to
-- the per-tick page cap within the wall-clock budget, and finalizes when the
-- last page is reached. Every failure is fail-SOFT (log-and-retry next tick):
-- a transient gh error must never crash the pipeline wrap.
-- Returns {status="complete"|"progress"|"retry"|"failed"|"no_clock", ...}.
function M.bootstrap_advance(opts)
  opts = opts or {}
  local clock = opts.clock or M.now_epoch
  local tick_start = clock()
  if tick_start == nil then
    return { status = "no_clock", pages = 0 }
  end
  -- env knobs, opts-overridable for the hermetic unit tests (which cannot set env)
  local budget = tonumber(opts.budget) or tonumber(M.read_env("FKST_TRIAGE_BOOTSTRAP_BUDGET")) or 20
  local page_timeout = tonumber(opts.page_timeout)
    or tonumber(M.read_env("FKST_TRIAGE_BOOTSTRAP_PAGE_TIMEOUT")) or 15
  local max_pages = tonumber(opts.max_pages) or tonumber(M.read_env("FKST_TRIAGE_BOOTSTRAP_PAGES")) or 3
  local max_age = tonumber(M.read_env("FKST_TRIAGE_MIRROR_MAX_AGE")) or 172800
  local repo = opts.repo or M.contrib_target()

  local cursor = M.read_bootstrap_cursor(opts)
  if cursor ~= nil then
    local began = tonumber(cursor.started_epoch)
    if began == nil or (tick_start - began) > max_age then
      M.reset_bootstrap(cursor, opts)
      cursor = nil
    end
  end
  if cursor == nil then
    cursor = { next_page = 1, started_epoch = tick_start }
  end

  local ckpt = M.mirror_checkpoint_dir(bootstrap_root(opts))
  local pages_done = 0
  while pages_done < max_pages do
    -- never START a page that could overrun the budget: elapsed plus a
    -- worst-case page_timeout fetch must fit, so the 30s stall window holds.
    local now_s = clock()
    if now_s == nil or (now_s - tick_start) + page_timeout > budget then
      break
    end
    local rows, is_end, err = M.bootstrap_fetch_page(repo, cursor.next_page, opts)
    if rows == nil then
      -- transient failure: the cursor stays on this page; retry next tick.
      return { status = "retry", pages = pages_done, next_page = cursor.next_page, error = err }
    end
    if is_end then
      local count, reason = M.finalize_bootstrap(cursor, opts)
      if count == nil then
        M.reset_bootstrap(cursor, opts)
        return { status = "failed", pages = pages_done, error = reason }
      end
      return { status = "complete", pages = pages_done, count = count }
    end
    local page_lines = {}
    for _, rec in ipairs(rows) do
      table.insert(page_lines, encode_compact_issue(rec))
    end
    ensure_dir(ckpt)
    local ok_page = pcall(file.write, bootstrap_page_path(ckpt, cursor.next_page),
      table.concat(page_lines, "\n") .. "\n")
    if not ok_page then
      return { status = "retry", pages = pages_done, next_page = cursor.next_page,
        error = "checkpoint write failed" }
    end
    cursor.next_page = cursor.next_page + 1
    pages_done = pages_done + 1
    M.write_bootstrap_cursor(cursor, opts)
  end
  return { status = "progress", pages = pages_done, next_page = cursor.next_page }
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

-- Scan the tracker's control issues (--state all: terminal issues are CLOSED as done
-- but must still settle their candidate) -> { [dedup_key] = stage }. Returns nil when
-- the scan cannot be read OR may be truncated (caller fails closed in live posture).
-- Rules:
--   - a CLOSED issue is FINAL regardless of labels (closed = done; also covers
--     migrated/manually-closed issues whose stage labels are gone),
--   - an OPEN non-final claim past the lease TTL is RELEASED (dead substrate),
--   - an unparseable updatedAt counts as FRESH (fail toward blocking).
-- The scan trusts any author: the tracker is the OWNED private repo and a colleague's
-- substrate may run under a different bot login.
function M.read_remote_claims(exec)
  local run = exec or exec_argv
  if type(run) ~= "function" then
    return nil
  end
  local ok, out = pcall(run, {
    argv = { "gh", "issue", "list", "--repo", M.tracker_repo(), "--label", "codex-saga:candidate",
      "--state", "all", "--limit", tostring(REMOTE_SCAN_LIMIT), "--json", "number,body,labels,updatedAt,state" },
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
      if tostring(issue.state or ""):upper() == "CLOSED" then
        -- closed = done: settle with the terminal label when present, else "closed".
        claims[dedup] = M.remote_claim_is_final(stage) and stage or "closed"
      else
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

function M.active_remote_claim_count(claims)
  local count = 0
  for _, stage in pairs(claims or {}) do
    if not M.remote_claim_is_final(stage) then
      count = count + 1
    end
  end
  return count
end

return M
