-- codex-triage mirror BOOTSTRAP tests (the in-package SLOW pull). Asserts: the
-- paced pull checkpoints pages + a resume cursor without ever swapping early; the
-- end-of-pages tick validates + swaps a complete non-partial mirror the consumer
-- accepts; a transient fetch failure retries the SAME page with NO side effects;
-- PR rows are excluded + body excerpts stay bounded (compact contract); the tick
-- budget stops a round before it could overrun the stall window; an expired
-- cursor restarts the pull instead of splicing days-old pages into a "fresh"
-- mirror. All hermetic: fetches are injected (opts.exec), no network, no gh.
-- G5: every *_test.lua must yield >=1 passing engine test.
local core = require("core")
local t = fkst.test

local function scratch_root(name)
  return (os.getenv("FKST_RUNTIME_ROOT") or ".") .. "/bootstrap-" .. tostring(name)
end

-- One raw GitHub issue row (the API shape, NOT the compact shape).
local function raw_issue(number, opts)
  opts = opts or {}
  local body = opts.body or ("repro body for issue " .. number)
  return string.format(
    '{"number":%d,"title":"issue %d","body":"%s",'
      .. '"labels":[{"name":"bug"},{"name":"exec"}],'
      .. '"reactions":{"total_count":%d},"updated_at":"2026-07-01T00:00:00Z"%s}',
    number, number, body, opts.reactions or 3,
    opts.pr and ',"pull_request":{"url":"x"}' or "")
end

-- Fake argv adapter serving fixed page bodies; pages beyond the table are empty
-- (= past the last page). Matches the &page=N param of the bootstrap endpoint.
local function fake_pages(pages)
  return function(spec)
    local endpoint = (spec.argv or {})[3] or ""
    local page = tonumber(endpoint:match("&page=(%d+)")) or 0
    return { exit_code = 0, stdout = pages[page] or "[]" }
  end
end

local function fixed_clock(value)
  return function()
    return value
  end
end

-- A deterministic clock that returns values[i] on the i-th call (clamped to the
-- last value), so budget arithmetic is exact.
local function seq_clock(values)
  local i = 0
  return function()
    i = i + 1
    return values[math.min(i, #values)]
  end
end

local TWO_PAGES = {
  [1] = "[" .. raw_issue(9101) .. "," .. raw_issue(9102) .. "," .. raw_issue(9103, { pr = true }) .. "]",
  [2] = "[" .. raw_issue(9104) .. "," .. raw_issue(9105) .. "]",
}

return {
  -- A paced round checkpoints pages + persists the resume cursor, WITHOUT
  -- creating a mirror: candidates must stay fail-closed mid-bootstrap.
  test_bootstrap_progresses_and_persists_cursor = function()
    local root = scratch_root("progress")
    local step = core.bootstrap_advance({
      root = root, exec = fake_pages(TWO_PAGES), clock = fixed_clock(1000),
      max_pages = 2, repo = "openai/codex",
    })
    t.eq(step.status, "progress")
    t.eq(step.pages, 2)
    t.eq(step.next_page, 3)
    local cursor = core.read_bootstrap_cursor({ root = root })
    t.is_true(cursor ~= nil)
    t.eq(cursor.next_page, 3)
    t.eq(cursor.started_epoch, 1000)
    -- page checkpoints exist in the reconcile_issues.py layout...
    local page1 = file.read(core.mirror_checkpoint_dir(root) .. "/page-0001.jsonl")
    t.is_true(type(page1) == "string" and page1:find('"number":9101', 1, true) ~= nil)
    -- ...but NO mirror was swapped in early.
    t.is_nil(core.load_cached_open_issues({ path = root .. "/codex-issue-mirror/open_issues.compact.jsonl" }))
  end,

  -- The end-of-pages tick combines + validates + swaps: the consumer-visible
  -- mirror appears complete, fresh, non-partial, and the checkpoint is cleared.
  test_bootstrap_completes_and_swaps_mirror = function()
    local root = scratch_root("complete")
    local exec = fake_pages(TWO_PAGES)
    local step1 = core.bootstrap_advance({
      root = root, exec = exec, clock = fixed_clock(1000),
      max_pages = 2, repo = "openai/codex",
    })
    t.eq(step1.status, "progress")
    local step2 = core.bootstrap_advance({
      root = root, exec = exec, clock = fixed_clock(1600),
      max_pages = 3, min_expected = 1, repo = "openai/codex",
    })
    t.eq(step2.status, "complete")
    t.eq(step2.count, 4) -- 5 raw rows minus the PR row

    local issues = core.load_cached_open_issues({ path = root .. "/codex-issue-mirror/open_issues.compact.jsonl" })
    t.is_true(issues ~= nil)
    t.eq(#issues, 4)
    t.eq(issues[1].number, 9101)
    t.eq(issues[1].source_ref.ref, "openai/codex#issues/9101")
    t.eq(issues[4].number, 9105)

    local st = core.mirror_state({ path = root .. "/codex-issue-mirror/reconcile_state.json" })
    t.is_true(st ~= nil)
    t.eq(st.partial, false)
    t.eq(st.count, 4)
    t.eq(tonumber(st.fresh_as_of_epoch), 1600)
    t.eq(st.producer, "codex-triage.bootstrap")
    -- reconcile_seconds spans the whole multi-tick pull (started at 1000).
    t.eq(tonumber(st.reconcile_seconds), 600)
    -- success clears the checkpoint + cursor.
    t.is_nil(core.read_bootstrap_cursor({ root = root }))
  end,

  -- A transient fetch failure is fail-SOFT: retry the SAME page next tick and
  -- leave NO checkpoint/cursor behind when nothing succeeded.
  test_bootstrap_retries_same_page_on_fetch_failure = function()
    local root = scratch_root("retry")
    local step = core.bootstrap_advance({
      root = root,
      exec = function() return { exit_code = 1, stderr = "boom" } end,
      clock = fixed_clock(1000),
      repo = "openai/codex",
    })
    t.eq(step.status, "retry")
    t.eq(step.pages, 0)
    t.eq(step.next_page, 1)
    t.is_nil(core.read_bootstrap_cursor({ root = root }))
  end,

  -- The compact contract holds at the fetch boundary: PR rows are excluded and
  -- body excerpts are BOUNDED (never full bodies).
  test_bootstrap_fetch_excludes_prs_and_bounds_bodies = function()
    local long_body = string.rep("x", 1500)
    local rows = core.bootstrap_fetch_page("openai/codex", 1, {
      exec = fake_pages({
        [1] = "[" .. raw_issue(9201, { body = long_body }) .. "," .. raw_issue(9202, { pr = true }) .. "]",
      }),
    })
    t.is_true(rows ~= nil)
    t.eq(#rows, 1) -- the PR row is dropped
    t.eq(rows[1].number, 9201)
    t.eq(#rows[1].body, 1000) -- BODY_EXCERPT bound, matches the python producer
    t.eq(rows[1].source_ref.ref, "openai/codex#issues/9201")
  end,

  -- The wall-clock budget stops a round BEFORE a page that could overrun the
  -- stall window: elapsed + page_timeout must fit inside the budget.
  test_bootstrap_budget_stops_round_early = function()
    local root = scratch_root("budget")
    -- calls: tick_start=100, gate#1=100 (0+15<=20: fetch page 1), gate#2=110
    -- (10+15>20: stop). max_pages alone would allow 3 pages.
    local step = core.bootstrap_advance({
      root = root, exec = fake_pages(TWO_PAGES), clock = seq_clock({ 100, 100, 110 }),
      max_pages = 3, repo = "openai/codex",
    })
    t.eq(step.status, "progress")
    t.eq(step.pages, 1)
    t.eq(step.next_page, 2)
  end,

  -- An EXPIRED cursor (pull started longer ago than the mirror freshness budget)
  -- restarts from page 1: days-old pages never splice into a "fresh" mirror.
  test_bootstrap_expired_cursor_restarts_pull = function()
    local root = scratch_root("expired")
    core.write_bootstrap_cursor({ next_page = 7, started_epoch = 1000 }, { root = root })
    local step = core.bootstrap_advance({
      root = root, exec = fake_pages(TWO_PAGES), clock = fixed_clock(1000 + 172801),
      max_pages = 1, repo = "openai/codex",
    })
    t.eq(step.status, "progress")
    t.eq(step.next_page, 2) -- restarted from page 1, not resumed at 7
    local cursor = core.read_bootstrap_cursor({ root = root })
    t.eq(cursor.next_page, 2)
    t.eq(cursor.started_epoch, 1000 + 172801)
  end,

  -- A degenerate end-of-pages pull (below min_expected) NEVER swaps in: the
  -- checkpoint resets so later ticks rebuild from page 1, and no mirror appears.
  test_bootstrap_degenerate_pull_fails_and_resets = function()
    local root = scratch_root("degenerate")
    local exec = fake_pages({ [1] = "[" .. raw_issue(9301) .. "]" })
    local step1 = core.bootstrap_advance({
      root = root, exec = exec, clock = fixed_clock(1000), max_pages = 1, repo = "openai/codex",
    })
    t.eq(step1.status, "progress")
    local step2 = core.bootstrap_advance({
      root = root, exec = exec, clock = fixed_clock(1300), max_pages = 2, repo = "openai/codex",
    }) -- page 2 is empty -> finalize -> 1 issue < min_expected 50 -> reset
    t.eq(step2.status, "failed")
    t.is_nil(core.load_cached_open_issues({ path = root .. "/codex-issue-mirror/open_issues.compact.jsonl" }))
    t.is_nil(core.read_bootstrap_cursor({ root = root }))
  end,

  -- Department-level: a missing mirror still raises NOTHING (fail-closed is
  -- preserved), while the bootstrap advances pages via the mocked gh adapter and
  -- persists its cursor for the next tick.
  test_score_dedup_bootstraps_when_mirror_missing = function()
    local root = (os.getenv("FKST_RUNTIME_ROOT") or ".") .. "/bootstrap-department"
    t.mock_command("gh api", { stdout = TWO_PAGES[1] })
    local result = t.run_department("departments/score_dedup/main.lua", {
      queue = "codex_issue_poll_tick",
      payload = { target = "openai/codex", clusters = {} },
    }, { env = { FKST_DURABLE_ROOT = root } })
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0) -- STILL fail-closed while bootstrapping
    -- the mock serves ONE gh api call: page 1 checkpoints, page 2 comes back
    -- unmocked (fails closed) -> the round ends in "retry" with the cursor
    -- persisted at page 2. Exactly the paced resume-next-tick contract.
    local cursor = core.read_bootstrap_cursor({ root = root })
    t.is_true(cursor ~= nil)
    t.eq(cursor.next_page, 2)
  end,
}
