-- codex-saga implement-core unit tests (DRY-RUN posture, no network). Exercise the
-- retrieval (precedent.tfidf over the PR-style fixture), the crate resolution
-- (repo_map.crate over the repo-structure fixtures, JSON + markdown), the fix prompt
-- contract, and the real codex-write path via INJECTED exec/codex (ZERO real cmds).
local core = require("core")
local tk = fkst.test

-- The PR-style fixture, read through the production reader (no network; file read).
local FIXTURE_CORPUS = "data/fixtures/corpus_pr_style.fixture.jsonl"
local FIXTURE_MAP_JSON = "data/fixtures/repo_structure.fixture.json"

return {
  -- Retrieval ranks the nearest merged-PR exemplar by touched-path overlap. The
  -- target's "agent interrupt continue" text matches #178 (agent-interrupt-continue
  -- test + agent-loop + terminal-chat) over the others.
  test_retrieve_pr_exemplars_ranks_nearest = function()
    local target = { title = "agent interrupt continue", body = "terminal chat agent loop interrupt continue" }
    local exemplars = core.retrieve_pr_exemplars(target, { path = FIXTURE_CORPUS, k = 3 })
    tk.is_true(#exemplars >= 1)
    tk.eq(exemplars[1].ref, "openai/codex#178")
  end,

  -- exemplar_refs flattens the ranked list to a small array of refs (no diffs).
  test_exemplar_refs_are_small = function()
    local refs = core.exemplar_refs({
      { ref = "openai/codex#178" },
      { source_ref = { ref = "openai/codex#1" } },
      { ref = "" },
    })
    tk.eq(#refs, 2)
    tk.eq(refs[1], "openai/codex#178")
    tk.eq(refs[2], "openai/codex#1")
  end,

  -- Crate resolution via repo_map.crate over the JSON repo-structure fixture: an
  -- area label resolves to its primary crate; a type label does not.
  test_resolve_target_crate_over_json_fixture = function()
    local resolved = core.resolve_target_crate({ "bug", "exec" }, { path = FIXTURE_MAP_JSON })
    tk.is_true(resolved ~= nil)
    tk.eq(resolved.area, "exec")
    tk.eq(resolved.crate, "codex-rs/exec")
  end,

  test_resolve_target_crate_unknown_labels_is_nil = function()
    tk.eq(core.resolve_target_crate({ "bug", "enhancement" }, { path = FIXTURE_MAP_JSON }), nil)
  end,

  -- build_repo_map also parses the production markdown table shape.
  test_build_repo_map_parses_markdown_table = function()
    local md = table.concat({
      "| Area label | Tier | fix-rate | Primary crate(s) / path | Notes |",
      "|---|---|---|---|---|",
      "| `exec` | A | 0.20 | `codex-rs/exec`, `exec-server` | command execution |",
      "| `regression` | A | 0.20 | _(cross-cutting)_ | bisect |",
    }, "\n")
    local map = core.build_repo_map(md)
    tk.eq(map.exec, "codex-rs/exec")
    -- a cross-cutting row with no backticked crate path is not mapped.
    tk.eq(map.regression, nil)
  end,

  -- The fix prompt carries the issue pointer, root cause, resolved crate, the
  -- exemplar refs, and the sentinel-delimited verdict contract.
  test_build_fix_prompt_includes_crate_and_exemplars = function()
    local prompt = core.build_fix_prompt(
      { kind = "external", ref = "openai/codex#1234" },
      "codex-rs/exec/mod.rs:88",
      { area = "exec", crate = "codex-rs/exec" },
      { { ref = "openai/codex#178" } }
    )
    tk.is_true(prompt:find("codex-rs/exec", 1, true) ~= nil)
    tk.is_true(prompt:find("openai/codex#178", 1, true) ~= nil)
    tk.is_true(prompt:find("FIX_WRITTEN:", 1, true) ~= nil)
  end,

  test_parse_fix_written_is_fail_closed = function()
    tk.eq(core.parse_fix_written("FIX_WRITTEN: yes\nFILES: a.rs"), true)
    tk.eq(core.parse_fix_written("FIX_WRITTEN: no"), false)
    tk.eq(core.parse_fix_written("garbage"), false)
  end,

  -- Dry-run (default posture): implement_write logs the intent and returns ok with
  -- NO real command, so the saga proceeds in demo mode.
  test_implement_write_dry_run_no_commands = function()
    local result = core.implement_write({
      dedup_key = "d1",
      fork_path = "/tmp/fakefork",
      branch = "codex-saga/fix-d1",
      prompt = "p",
      crate = { area = "exec", crate = "codex-rs/exec" },
    })
    tk.eq(result.mode, "dry-run")
    tk.eq(result.ok, true)
    tk.eq(result.crate, "codex-rs/exec")
    tk.eq(#tk.command_calls(), 0)
  end,

  -- The real codex-write path via INJECTED exec/codex: it writes the fix (codex says
  -- FIX_WRITTEN: yes) and returns ok, exercising the prompt->codex->commit path with
  -- ZERO real commands (everything injected; fork_push stays dry-run).
  test_run_implementation_writes_fix_with_injected_codex = function()
    local calls = {}
    local fake_exec = function(opts)
      table.insert(calls, opts.argv[1] .. " " .. (opts.argv[5] or opts.argv[2] or ""))
      return { exit_code = 0, stdout = "" }
    end
    local fake_codex = function(_opts)
      return { exit_code = 0, stdout = "FIX_WRITTEN: yes\nFILES: codex-rs/exec/mod.rs" }
    end
    local result = core.run_implementation({
      dedup_key = "d1",
      fork_path = "/tmp/fakefork",
      branch = "codex-saga/fix-d1",
      prompt = core.build_fix_prompt({ ref = "openai/codex#1234" }, "codex-rs/exec/mod.rs:88",
        { area = "exec", crate = "codex-rs/exec" }, {}),
      crate = { area = "exec", crate = "codex-rs/exec" },
      exec = fake_exec,
      codex = fake_codex,
    })
    tk.eq(result.ok, true)
    tk.eq(result.crate, "codex-rs/exec")
    -- injected exec ran the worktree/commit git ops; no REAL command was performed.
    tk.is_true(#calls >= 1)
    tk.eq(#tk.command_calls(), 0)
  end,

  -- When codex reports no fix, run_implementation returns ok=false (the dept drops).
  test_run_implementation_no_fix_returns_not_ok = function()
    local fake_exec = function(_) return { exit_code = 0, stdout = "" } end
    local fake_codex = function(_) return { exit_code = 0, stdout = "FIX_WRITTEN: no" } end
    local result = core.run_implementation({
      dedup_key = "d1", fork_path = "/tmp/fakefork", branch = "b", prompt = "p",
      crate = nil, exec = fake_exec, codex = fake_codex,
    })
    tk.eq(result.ok, false)
  end,
}
