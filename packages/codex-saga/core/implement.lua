-- core.implement: the WRITE-CLASS fix step's retrieval + fix-write logic.
--
-- This is the learning loop's "Implementation" arm (docs/learning-model.md §1/§4/§7):
--   1. retrieve the nearest merged-PR exemplars via precedent.tfidf over the
--      corpus_pr_style bank (refs only carried forward, NEVER diffs/bodies);
--   2. resolve the target crate via repo_map.crate over the area->crate map
--      (codex-repo-structure), so the fix is routed at the right code;
--   3. build a fix prompt and spawn_codex_sync to WRITE the fix on a fork worktree.
--
-- Posture (spec §10, two-plane): the codex-write-and-push is a WRITE-CLASS effect,
-- DRY-RUN BY DEFAULT. In dry-run it logs the intent and runs ZERO real commands; the
-- genuinely-once codex write + commit + fork push happens only under
-- FKST_GITHUB_WRITE=1, gated on once()/marker (the codex-saga owned fork-push
-- pattern, mirroring core.egress). precedent.tfidf + repo_map.crate are PURE: this
-- module supplies the corpus/map DATA (read via a path; fixtures injected in tests).
local S = {}

local precedent = require("precedent.tfidf")
local crate_map = require("repo_map.crate")

local DEFAULT_K = 3

function S.install(M)
  -- ---- corpus + map source paths (production default; injectable in tests) -----
  function M.pr_style_corpus_path()
    local override = M.read_env("FKST_PR_STYLE_CORPUS")
    if M.is_nonempty_string(override) then
      return override
    end
    return M.env_or("FKST_SAGA_DATA_DIR", "data") .. "/corpus_pr_style.jsonl"
  end

  function M.repo_structure_path()
    local override = M.read_env("FKST_REPO_STRUCTURE")
    if M.is_nonempty_string(override) then
      return override
    end
    return M.env_or("FKST_SAGA_DATA_DIR", "data") .. "/codex-repo-structure.md"
  end

  -- Read + decode the merged-PR style corpus. Degrades gracefully ({}) when the
  -- data file is absent/unreadable (the saga still proceeds without exemplars).
  -- opts.records / opts.text inject fixtures in tests; opts.path overrides the path.
  function M.read_pr_style_corpus(opts)
    opts = opts or {}
    if opts.records ~= nil then
      return opts.records
    end
    local text = opts.text
    if text == nil then
      local path = opts.path or M.pr_style_corpus_path()
      if not file.exists(path) then
        return {}
      end
      local ok, contents = pcall(file.read, path)
      if not ok then
        return {}
      end
      text = contents
    end
    return M.decode_corpus(text)
  end

  -- ---- repo_map: build a flat { [area] = crate } map for repo_map.crate --------
  -- The map DATA is the CALLER's responsibility (the library is pure); we normalize
  -- both the JSON shape ({areas={[area]={crates=[...]}}}) and the markdown table in
  -- data/codex-repo-structure.md into the flat map repo_map.crate.resolve expects.
  function M.parse_repo_structure_markdown(text)
    local map = {}
    for line in tostring(text or ""):gmatch("[^\n]+") do
      if line:find("^%s*|") ~= nil then
        local area, crate
        for token in line:gmatch("`([^`]+)`") do
          if area == nil then
            area = token
          end
          if crate == nil and token:find("/", 1, true) ~= nil then
            crate = token
          end
        end
        if area ~= nil and crate ~= nil and area:find("/", 1, true) == nil then
          map[area:lower()] = crate
        end
      end
    end
    return map
  end

  function M.build_repo_map(source)
    local decoded = nil
    if type(source) == "table" then
      decoded = source
    elseif type(source) == "string" then
      local ok, d = pcall(json.decode, source)
      if ok and type(d) == "table" then
        decoded = d
      end
    end
    if type(decoded) == "table" and type(decoded.areas) == "table" then
      local map = {}
      for area, info in pairs(decoded.areas) do
        local crate = nil
        if type(info) == "table" and type(info.crates) == "table" then
          crate = info.crates[1]
        elseif type(info) == "string" then
          crate = info
        end
        if type(area) == "string" and type(crate) == "string" then
          map[area:lower()] = crate
        end
      end
      return map
    end
    if type(source) == "string" then
      return M.parse_repo_structure_markdown(source)
    end
    return {}
  end

  -- Load the flat area->crate map. opts.map / opts.text inject in tests; opts.path
  -- overrides; default reads data/codex-repo-structure.md. Degrades to {} on miss.
  function M.load_repo_map(opts)
    opts = opts or {}
    if opts.map ~= nil then
      return opts.map
    end
    local text = opts.text
    if text == nil then
      local path = opts.path or M.repo_structure_path()
      if not file.exists(path) then
        return {}
      end
      local ok, contents = pcall(file.read, path)
      if not ok then
        return {}
      end
      text = contents
    end
    return M.build_repo_map(text)
  end

  -- Resolve the target crate for the candidate's labels via repo_map.crate. Returns
  -- { area, crate } for the first label that maps to a crate, or nil (fail-soft to
  -- "no known crate"; the fix still proceeds, just unrouted).
  function M.resolve_target_crate(labels, opts)
    local map = M.load_repo_map(opts)
    return crate_map.resolve_labels(map, labels or {})
  end

  -- ---- retrieval: nearest merged-PR exemplars (precedent.tfidf) ----------------
  -- A PR-style record carries no title/body; synthesize a precedent-friendly doc
  -- from its touched_paths so the TF-IDF cosine reflects path/crate overlap with the
  -- target. Only the small {ref, source_ref} is ever carried forward.
  function M.pr_exemplar_doc(record)
    local ref = nil
    if type(record.source_ref) == "table" then
      ref = record.source_ref.ref
    end
    local paths = {}
    for _, path in ipairs(record.touched_paths or {}) do
      table.insert(paths, tostring(path))
    end
    local joined = table.concat(paths, " ")
    return {
      ref = ref,
      source_ref = record.source_ref,
      title = joined,
      body = joined,
      touched_paths = record.touched_paths,
      merged = record.merged,
    }
  end

  function M.build_pr_exemplar_docs(records)
    local docs = {}
    for _, record in ipairs(records or {}) do
      if type(record) == "table" and record.merged ~= false then
        table.insert(docs, M.pr_exemplar_doc(record))
      end
    end
    return docs
  end

  -- The retrieval target: the candidate's root cause + resolved crate + labels.
  function M.implement_target(payload, crate)
    payload = payload or {}
    local parts = {}
    if M.is_nonempty_string(payload.root_cause) then
      table.insert(parts, payload.root_cause)
    end
    if type(crate) == "table" and M.is_nonempty_string(crate.crate) then
      table.insert(parts, crate.crate)
    end
    for _, label in ipairs(payload.labels or {}) do
      table.insert(parts, tostring(label))
    end
    local text = table.concat(parts, " ")
    return { title = text, body = text }
  end

  -- Rank the merged-PR exemplars nearest the target and return a SMALL normalized
  -- list { {ref, source_ref, cosine}, ... } (refs only - no diffs/bodies).
  function M.retrieve_pr_exemplars(target, opts)
    opts = opts or {}
    local docs = M.build_pr_exemplar_docs(M.read_pr_style_corpus(opts))
    local ranked = precedent.rank(target, docs, { k = opts.k or DEFAULT_K })
    local out = {}
    for _, entry in ipairs(ranked) do
      local doc = entry.issue or {}
      table.insert(out, { ref = doc.ref, source_ref = doc.source_ref, cosine = entry.cosine })
    end
    return out
  end

  function M.exemplar_refs(exemplars)
    local refs = {}
    for _, exemplar in ipairs(exemplars or {}) do
      local ref = exemplar.ref
      if ref == nil and type(exemplar.source_ref) == "table" then
        ref = exemplar.source_ref.ref
      end
      if M.is_nonempty_string(ref) then
        table.insert(refs, ref)
      end
    end
    return refs
  end

  -- ---- fix prompt + verdict parse ---------------------------------------------
  function M.build_fix_prompt(entity, root_cause, crate, exemplars)
    local ref = "(none)"
    if type(entity) == "table" and type(entity.ref) == "string" then
      ref = entity.ref
    end
    local crate_line = "(unresolved)"
    if type(crate) == "table" and M.is_nonempty_string(crate.crate) then
      crate_line = crate.crate
    end
    local lines = {
      "You are implementing a focused fix for an open-source bug on a writable fork worktree.",
      "Issue pointer: " .. ref,
      "Root cause: " .. tostring(root_cause or "(unknown)"),
      "Target crate / path: " .. crate_line,
      "Imitate the size and shape of these merged-PR exemplars (refs only; fetch as needed):",
    }
    for _, exemplar in ipairs(exemplars or {}) do
      table.insert(lines, "  - " .. tostring(exemplar.ref or "(ref)"))
    end
    table.insert(lines, "Keep the change small (<=3 files / <=200 LOC), add a fail-before/pass-after test, and follow repo conventions.")
    table.insert(lines, "Respond with exactly three lines:")
    table.insert(lines, "FIX_WRITTEN: yes   (or)   FIX_WRITTEN: no")
    table.insert(lines, "FILES: <comma-separated changed paths>   (omit if no fix)")
    table.insert(lines, "APPROACH: <1-2 sentences on one line: what the fix changes and how the added test proves it>")
    return table.concat(lines, "\n")
  end

  -- Fail-closed: only an explicit "yes" counts as a written fix.
  function M.parse_fix_written(stdout)
    local verdict = tostring(stdout or ""):match("FIX_WRITTEN:%s*(%a+)")
    return verdict ~= nil and verdict:lower() == "yes"
  end

  -- Parse a single-line marker value ("FILES: ...", "APPROACH: ..."), rejecting empty
  -- and template placeholders. Board detail only; NEVER carried on event payloads.
  -- codex-derived text from public issue content: marker namespace neutralized so it
  -- can never forge a bot-authored fkst marker downstream.
  local function parse_marker_line(stdout, marker)
    local raw = tostring(stdout or ""):match(marker .. ":%s*([^\r\n]+)")
    if raw == nil then
      return nil
    end
    local trimmed = M.trim(raw)
    if trimmed == "" or trimmed:find("^<") ~= nil then
      return nil
    end
    return M.strip_marker_namespace(trimmed)
  end

  function M.parse_files(stdout)
    return parse_marker_line(stdout, "FILES")
  end

  function M.parse_approach(stdout)
    return parse_marker_line(stdout, "APPROACH")
  end

  -- ---- the write-class fix effect (dry-run by default) -------------------------
  -- DRY-RUN: log the intent and return { ok=true, mode="dry-run" } with NO commands,
  -- so the saga proceeds in demo mode referencing the intended fix branch. REAL
  -- (FKST_GITHUB_WRITE=1): gate the genuinely-once write on once()/the fork branch.
  -- req = { dedup_key, fork_path, branch, prompt, crate, exec?, codex? }.
  function M.implement_write(req)
    local mode = M.write_mode()
    local crate_path = (type(req.crate) == "table" and req.crate.crate) or "(unresolved)"
    log.info(string.format("OUTBOUND mode=%s op=implement-fix repo=%s branch=%s crate=%s",
      mode, tostring(M.fork_repo()), tostring(req.branch), tostring(crate_path)))

    if mode ~= "real" then
      log.info("codex-saga dry-run: would run codex to write the fix on "
        .. tostring(req.branch) .. " and push to the fork (no real commands)")
      return { ok = true, mode = "dry-run", branch = req.branch, crate = crate_path }
    end

    if not M.is_nonempty_string(req.fork_path) then
      error("codex-saga: implement requires FKST_FORK_LOCAL_PATH for a real write")
    end
    local result = { ok = false, mode = "real", branch = req.branch, crate = crate_path }
    local ran = once(M.step_key("implement", req.dedup_key), function()
      result = M.run_implementation(req)
    end)
    if not ran then
      -- marker present: the fix was already written this runtime; proceed idempotently.
      result = { ok = true, mode = "real", branch = req.branch, crate = crate_path, skipped = true }
    end
    return result
  end

  -- The real codex-write path (exec/codex injected in tests). Creates a fork
  -- worktree, runs codex to apply the fix, and on success commits + pushes the fix
  -- branch via the gated fork-push pattern. Returns { ok, mode, branch, crate }.
  function M.run_implementation(req)
    local exec = req.exec
    local codex = req.codex
    if type(codex) ~= "function" then
      codex = function(o)
        return spawn_codex_sync(o)
      end
    end
    local rt = M.env_or("FKST_RUNTIME_ROOT", ".")
    local worktree = rt .. "/worktrees/codex-saga-implement-" .. M.safe_segment(req.dedup_key)
    local crate_path = (type(req.crate) == "table" and req.crate.crate) or "(unresolved)"

    M.run_argv({
      argv = { "git", "-C", tostring(req.fork_path), "worktree", "add", "--detach", worktree, "HEAD" },
      timeout = 60,
    }, exec)

    local out = codex({ prompt = req.prompt, worktree = worktree, timeout = 1800 })
    local stdout = (type(out) == "table" and out.stdout) or ""
    local written = M.parse_fix_written(stdout)
    local result = { ok = written, mode = "real", branch = req.branch, crate = crate_path,
      files = M.parse_files(stdout), approach = M.parse_approach(stdout) }

    if written then
      M.run_argv({ argv = { "git", "-C", worktree, "checkout", "-B", tostring(req.branch) }, timeout = 30 }, exec)
      M.run_argv({ argv = { "git", "-C", worktree, "add", "-A" }, timeout = 30 }, exec)
      M.run_argv({
        argv = { "git", "-C", worktree, "commit", "-m", "codex-saga: fix " .. tostring(req.dedup_key) },
        timeout = 60,
      }, exec)
      M.fork_push_intent(req.fork_path, req.branch, req.dedup_key, exec)
    end

    -- Best-effort worktree cleanup (failure must not mask the implementation result).
    pcall(M.run_argv, {
      argv = { "git", "-C", tostring(req.fork_path), "worktree", "remove", "--force", worktree },
      timeout = 60,
    }, exec)
    return result
  end
end

return S
