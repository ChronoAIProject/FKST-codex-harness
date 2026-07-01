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
      "Respond with exactly two lines:",
      "REPRODUCED: yes   (or)   REPRODUCED: no",
      "ROOT_CAUSE: <path>:<line>   (omit if not reproduced)",
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
    return trimmed
  end

  -- Reproduce + diagnose on a fork worktree. opts.exec / opts.codex inject the
  -- exec_argv / spawn_codex_sync primitives for testing. Returns
  -- { reproduced = bool, root_cause = string|nil }.
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

    -- Best-effort worktree cleanup (failure must not mask the diagnosis result).
    pcall(M.run_argv, {
      argv = { "git", "-C", tostring(fork_path), "worktree", "remove", "--force", worktree },
      timeout = 60,
    }, exec)

    return { reproduced = reproduced, root_cause = root_cause }
  end
end

return S
