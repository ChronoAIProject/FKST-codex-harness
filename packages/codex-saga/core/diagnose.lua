-- core.diagnose: local reproduction + root-cause extraction on the fork.
--
-- diagnose is local + read-only to the public (spec §5): it creates a git worktree
-- on the fork checkout, runs codex to reproduce, and parses a root cause at
-- file:line. No foreign-plane write happens here. The reproduce/root-cause prompt
-- contract is sentinel-delimited so the parse is injection-hardened.
local S = {}

function S.install(M)
  -- The read-only reproduction prompt. Internal prompt (English code), not locale.
  function M.reproduce_prompt(entity)
    local ref = "(none)"
    if type(entity) == "table" and type(entity.ref) == "string" then
      ref = entity.ref
    end
    local lines = {
      "You are diagnosing an open-source bug report on a read-only checkout.",
      "Issue pointer: " .. ref,
      "Attempt to reproduce the reported behavior from the issue. Do not modify files.",
      "Then identify the most likely root cause location.",
      "Respond with exactly three lines:",
      "REPRODUCED: yes   (or)   REPRODUCED: no",
      "ROOT_CAUSE: <path>:<line>   (omit if not reproduced)",
      "EVIDENCE: <1-3 sentences on one line: what you observed, and why this location is the root cause (or why it could not be reproduced)>",
    }
    return table.concat(lines, "\n")
  end

  -- Parse the reproduction verdict. Fail-closed: only an explicit "yes" reproduces.
  function M.parse_reproduced(stdout)
    local verdict = tostring(stdout or ""):match("REPRODUCED:%s*(%a+)")
    return verdict ~= nil and verdict:lower() == "yes"
  end

  -- Parse the root cause at file:line from the codex output. Returns the trimmed
  -- "path:line" string, or nil when absent.
  function M.parse_root_cause(stdout)
    local raw = tostring(stdout or ""):match("ROOT_CAUSE:%s*([^\r\n]+)")
    if raw == nil then
      return nil
    end
    local trimmed = M.trim(raw)
    if trimmed == "" or trimmed:find("^<") ~= nil then
      return nil
    end
    -- codex-derived text from public issue content: marker namespace neutralized so it
    -- can never forge a bot-authored fkst marker downstream.
    return M.strip_marker_namespace(trimmed)
  end

  -- Verify a parsed "path:line" root cause against the checkout at base_dir. It must be
  -- file:line shaped, name a repo-relative path (no absolute path / no `..` or `.git`
  -- segment - the value is codex-derived from PUBLIC issue content, so a forged pointer
  -- must not escape the worktree or point at git internals), that path must be a git-
  -- TRACKED file in the checkout (not `.git`, an untracked/generated file, or anything
  -- outside the tree - existence alone is NOT enough: worktree/.git is itself readable),
  -- and the line number must fall within that file. Returns true only when all hold; a
  -- false result DOWNGRADES the downstream claim to "suspected" (via root_cause_verified)
  -- and NEVER blocks the saga. Fail-closed on any git/read error. `exec` injects the
  -- exec_argv adapter in tests (mirrors run_diagnosis).
  function M.verify_root_cause(root_cause, base_dir, exec)
    if not M.is_nonempty_string(root_cause) or not M.is_nonempty_string(base_dir) then
      return false
    end
    local path, line = root_cause:match("^(.-):(%d+)$")
    if path == nil or path == "" then
      return false
    end
    if path:find("^/") ~= nil then
      return false
    end
    for seg in (path .. "/"):gmatch("([^/]*)/") do
      if seg == ".." or seg == ".git" then
        return false
      end
    end
    local lineno = tonumber(line)
    if lineno == nil or lineno < 1 then
      return false
    end
    -- Tracked-file gate: `git ls-files --error-unmatch` exits non-zero for an untracked/
    -- absent path or one that escapes the tree, so a readable-but-untracked file (or a
    -- `.git` internal) can never be asserted as a verified root cause. Fail-closed. The
    -- `:(literal)` pathspec magic disables wildcard/pathspec interpretation, so a value
    -- like `*.rs:1` cannot glob-match a tracked file.
    local ok_ls, out = pcall(M.run_argv, {
      argv = { "git", "-C", tostring(base_dir), "ls-files", "--error-unmatch", "--",
        ":(literal)" .. path },
      timeout = 30,
    }, exec)
    if not ok_ls or type(out) ~= "table" or out.exit_code ~= 0 then
      return false
    end
    -- Line-in-range: read the tracked file and bound the line number by its line count.
    local ok, contents = pcall(file.read, base_dir .. "/" .. path)
    if not ok or type(contents) ~= "string" or contents == "" then
      return false
    end
    local _, newlines = contents:gsub("\n", "\n")
    -- File line count: newline chars, +1 when the file does not end in a newline (its
    -- final, unterminated line). A trailing newline does not add an extra (empty) line.
    local max_line = newlines + (contents:sub(-1) == "\n" and 0 or 1)
    return lineno <= max_line
  end

  -- Whether the diagnosis step should ACTUALLY create a fork worktree and spawn codex.
  -- Spec §5 makes diagnose "local + read-only to the public" (sandbox=read-only), so a
  -- real local reproduction is legitimate and EXPECTED - the honest default is LIVE
  -- (true). This is the explicit, documented gate that core.implement's write-mode has
  -- but diagnose lacked: implement's codex run WRITES to the fork (write-class) so it is
  -- gated OFF by default behind FKST_GITHUB_WRITE; diagnose's codex run only READS, so it
  -- runs by default and is opted OUT (CI / demo hosts without codex or a fork checkout)
  -- via FKST_DIAGNOSE_SIMULATE=1. The DEPARTMENT applies this as a clean top-level no-op
  -- (skip - no claim, no codex, no fabricated drop), mirroring how implement's wrapper
  -- (implement_write) owns the gate while run_implementation/run_diagnosis stay pure.
  function M.diagnose_live()
    return M.read_env("FKST_DIAGNOSE_SIMULATE") ~= "1"
  end

  -- Parse the EVIDENCE narrative (what was observed / why this is the root cause, or
  -- why it did not reproduce). Returns the trimmed single-line summary, or nil when
  -- absent or a template placeholder. Board detail only (posted as a progress
  -- comment); NEVER carried on event payloads. Marker namespace neutralized.
  function M.parse_evidence(stdout)
    local raw = tostring(stdout or ""):match("EVIDENCE:%s*([^\r\n]+)")
    if raw == nil then
      return nil
    end
    local trimmed = M.trim(raw)
    if trimmed == "" or trimmed:find("^<") ~= nil then
      return nil
    end
    return M.strip_marker_namespace(trimmed)
  end

  -- Reproduce + diagnose on a fork worktree. Pure mechanism: it ALWAYS creates the
  -- worktree + runs codex (the department applies the M.diagnose_live() no-op gate, so a
  -- directly-injected opts.codex/opts.exec run is never skipped by host env). opts.exec /
  -- opts.codex inject the exec_argv / spawn_codex_sync primitives for testing. Returns
  -- { reproduced = bool, root_cause = string|nil, root_cause_verified = bool,
  --   evidence = string|nil }. `reproduced` is the codex self-report that gates saga
  -- flow (advance vs needs_info drop); it is NOT a verified reproduction (none is
  -- implemented), so the department threads a separate honest reproduced=false onward.
  function M.run_diagnosis(entity, fork_path, dedup_key, opts)
    opts = opts or {}
    local exec = opts.exec
    local codex = opts.codex
    if type(codex) ~= "function" then
      codex = function(o)
        return spawn_codex_sync(o)
      end
    end

    local rt = M.env_or("FKST_RUNTIME_ROOT", ".")
    local worktree = rt .. "/worktrees/codex-saga-diagnose-" .. M.safe_segment(dedup_key)

    -- A worktree on the fork checkout (owned plane); reproduction is read-only.
    M.run_argv({
      argv = { "git", "-C", tostring(fork_path), "worktree", "add", "--detach", worktree, "HEAD" },
      timeout = 60,
    }, exec)

    local out = codex({
      prompt = M.reproduce_prompt(entity),
      worktree = worktree,
      sandbox = "read-only",
      timeout = 1800,
    })
    local stdout = (type(out) == "table" and out.stdout) or ""
    local reproduced = M.parse_reproduced(stdout)
    local root_cause = M.parse_root_cause(stdout)
    local evidence = M.parse_evidence(stdout)

    -- Validate the parsed root cause against the LIVE worktree BEFORE it is torn down:
    -- a valid pointer (a tracked file:line in the checkout) is required to ASSERT the
    -- root cause downstream; otherwise the claim is downgraded to "suspected" via the flag.
    local root_cause_verified = M.verify_root_cause(root_cause, worktree, exec)

    -- Best-effort worktree cleanup (failure must not mask the diagnosis result).
    pcall(M.run_argv, {
      argv = { "git", "-C", tostring(fork_path), "worktree", "remove", "--force", worktree },
      timeout = 60,
    }, exec)

    return { reproduced = reproduced, root_cause = root_cause,
      root_cause_verified = root_cause_verified, evidence = evidence }
  end
end

return S
