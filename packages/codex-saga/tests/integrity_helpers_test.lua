-- Integrity-helper unit tests (DRY-RUN; no network). Cover the two ownership-split
-- fixes whose owning agents could not add tests (they were scoped to source files only):
--   * diagnose.lua  verify_root_cause / parse_root_cause  (#1: never assert an unverified
--     root cause) - the reject branches here need no real fs/git (exec is injected).
--   * implement.lua build_validation_summary / parse_test_* (#6/#7: honest, real validation
--     line, never a fabricated pass).
local core = require("core")
local tk = fkst.test

return {
  -- #1: verify_root_cause rejects anything that is not a safe, repo-relative file:line,
  -- BEFORE touching git/the filesystem (these branches short-circuit, so no injection).
  test_verify_root_cause_rejects_unsafe_or_malformed = function()
    tk.eq(core.verify_root_cause("not a pointer", ".", nil), false) -- not file:line shaped
    tk.eq(core.verify_root_cause("src/foo.rs", ".", nil), false)    -- missing :line
    tk.eq(core.verify_root_cause("/etc/passwd:1", ".", nil), false) -- absolute escapes worktree
    tk.eq(core.verify_root_cause("../secret.rs:1", ".", nil), false)-- parent traversal
    tk.eq(core.verify_root_cause(".git/config:1", ".", nil), false) -- git internals
    tk.eq(core.verify_root_cause("src/foo.rs:0", ".", nil), false)  -- non-positive line
    tk.eq(core.verify_root_cause("", ".", nil), false)              -- empty root cause
    tk.eq(core.verify_root_cause("src/foo.rs:1", "", nil), false)   -- empty base_dir
  end,

  -- #1: a well-shaped pointer whose path is NOT git-tracked fails closed - a readable-but-
  -- untracked (or generated) file can never be asserted as a verified root cause. Injected
  -- exec stands in for `git ls-files --error-unmatch` returning non-zero.
  test_verify_root_cause_untracked_fails_closed = function()
    local calls = 0
    local exec = function(opts)
      calls = calls + 1
      return { exit_code = 1, stdout = "", stderr = "did not match any file(s) known to git" }
    end
    tk.eq(core.verify_root_cause("src/generated.rs:5", ".", exec), false)
    tk.is_true(calls >= 1) -- it consulted git before deciding (not a shape short-circuit)
  end,

  -- #1: parse_root_cause extracts the pointer and rejects the unfilled placeholder so a
  -- template echo can never become an asserted root cause.
  test_parse_root_cause_extracts_and_rejects_placeholder = function()
    tk.eq(core.parse_root_cause("ROOT_CAUSE: src/exec/mod.rs:42"), "src/exec/mod.rs:42")
    tk.eq(core.parse_root_cause("ROOT_CAUSE: <path>:<line>"), nil)
    tk.eq(core.parse_root_cause("no marker present"), nil)
  end,

  -- #7: build_validation_summary is HONEST across all four branches - it states what ran
  -- and how it went, carries a lone result, admits a missing result, and NEVER invents a
  -- pass when codex reported nothing.
  test_build_validation_summary_is_honest = function()
    tk.eq(core.build_validation_summary("cargo test -p codex-exec", "3 passed"),
      "ran `cargo test -p codex-exec` → 3 passed")
    tk.eq(core.build_validation_summary("cargo test", nil),
      "ran `cargo test` (result not reported)")
    tk.eq(core.build_validation_summary(nil, "all green locally"), "all green locally")
    tk.eq(core.build_validation_summary(nil, nil), "no test command reported by codex")
  end,

  -- #7: parse_test_command / parse_test_result read the codex markers; absent markers
  -- return nil so the dossier falls back honestly rather than to a fabricated command.
  test_parse_test_markers = function()
    local out = "FIX_WRITTEN: yes\nTEST_COMMAND: cargo test -p codex-tui\nTEST_RESULT: 3 passed\n"
    tk.eq(core.parse_test_command(out), "cargo test -p codex-tui")
    tk.eq(core.parse_test_result(out), "3 passed")
    tk.eq(core.parse_test_command("FIX_WRITTEN: yes\n"), nil)
    tk.eq(core.parse_test_result("FIX_WRITTEN: yes\n"), nil)
  end,
}
