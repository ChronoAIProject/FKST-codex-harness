-- core.egress: OWNED gh/git egress helper, mirroring github-proxy's outbound model.
--
-- Posture (spec §10, two-plane discipline): DRY-RUN BY DEFAULT. A write-class effect
-- records and returns an intent without any external mutation; it performs the real
-- gh/git call ONLY under FKST_GITHUB_WRITE=1, behind a process lock, gated on the
-- bot-authored GitHub marker (the durable idempotency truth). All gh/git go through
-- the exec_argv adapter (shell-free; never raw command heads in business code).
local S = {}

local GH = "gh"
local GIT = "git"

function S.install(M)
  -- The argv adapter: the single egress path to exec_argv. Business code builds
  -- typed argv tables and never constructs raw shell command heads.
  local function run_argv(opts, exec)
    local run = exec or exec_argv
    if type(run) ~= "function" then
      error("codex-saga: egress requires exec_argv")
    end
    if type(opts) ~= "table" or type(opts.argv) ~= "table" or opts.argv[1] == nil then
      error("codex-saga: egress argv must be a non-empty array")
    end
    return run(opts)
  end
  M.run_argv = run_argv

  -- Outbound posture is dry-run unless the host explicitly opts into real writes.
  function M.write_mode()
    return M.read_env("FKST_GITHUB_WRITE") == "1" and "real" or "dry-run"
  end

  -- ---- gh / git argv builders (program head only via the adapter) -------------
  function M.gh_issue_comment_argv(repo, number, body_file)
    return {
      argv = { GH, "issue", "comment", tostring(number), "--repo", tostring(repo), "--body-file", body_file },
      timeout = 30,
    }
  end

  function M.gh_issue_create_argv(repo, title, body_file, labels)
    local argv = { GH, "issue", "create", "--repo", tostring(repo), "--title", tostring(title), "--body-file", body_file }
    for _, label in ipairs(labels or {}) do
      table.insert(argv, "--label")
      table.insert(argv, tostring(label))
    end
    return { argv = argv, timeout = 30 }
  end

  -- Add a label to an existing issue (idempotent in gh). Used to stamp the engage-time
  -- `engaged` label onto a control issue that was ADOPTED earlier with the `candidate`
  -- label (core.progress); the durable volume cap + invite/outcome scans key off it.
  function M.gh_issue_add_label_argv(repo, number, label)
    return {
      argv = { GH, "issue", "edit", tostring(number), "--repo", tostring(repo), "--add-label", tostring(label) },
      timeout = 30,
    }
  end

  -- Swap labels on an issue in one call: add each of add_labels, remove each of
  -- remove_labels (gh no-ops a remove of an absent label). Used for the current-stage
  -- label swap (core.progress.set_state_label).
  function M.gh_issue_edit_labels_argv(repo, number, add_labels, remove_labels)
    local argv = { GH, "issue", "edit", tostring(number), "--repo", tostring(repo) }
    for _, label in ipairs(add_labels or {}) do
      table.insert(argv, "--add-label")
      table.insert(argv, tostring(label))
    end
    for _, label in ipairs(remove_labels or {}) do
      table.insert(argv, "--remove-label")
      table.insert(argv, tostring(label))
    end
    return { argv = argv, timeout = 30 }
  end

  function M.gh_issue_view_argv(repo, number, fields)
    return {
      argv = { GH, "issue", "view", tostring(number), "--repo", tostring(repo), "--json", fields or "comments,assignees,labels,state" },
      timeout = 30,
    }
  end

  -- state defaults to "open"; pass "all" for locators that must still find issues
  -- CLOSED as done (close-on-terminal board semantics).
  function M.gh_issue_list_argv(repo, label, fields, state)
    return {
      argv = { GH, "issue", "list", "--repo", tostring(repo), "--label", tostring(label), "--state", tostring(state or "open"), "--json", fields or "number,title,labels" },
      timeout = 30,
    }
  end

  function M.gh_issue_close_argv(repo, number)
    return {
      argv = { GH, "issue", "close", tostring(number), "--repo", tostring(repo) },
      timeout = 30,
    }
  end

  -- Today's engagement control issues on the tracker, scoped to today by the gh
  -- search query (so the durable volume-cap count needs no client-side date math).
  function M.gh_engagement_list_argv(repo, today)
    return {
      -- --state all: an engagement that already settled (issue CLOSED as done) still
      -- counts toward today's volume cap.
      argv = { GH, "issue", "list", "--repo", tostring(repo), "--label", M.state_label("engaged"),
        "--state", "all", "--search", "created:>=" .. tostring(today), "--json", "number,author,body" },
      timeout = 30,
    }
  end

  function M.gh_pr_create_argv(opts, body_file)
    return {
      argv = { GH, "pr", "create", "--repo", tostring(opts.base_repo), "--head", tostring(opts.head),
        "--base", tostring(opts.base), "--title", tostring(opts.title), "--body-file", body_file },
      timeout = 60,
    }
  end

  function M.git_fork_push_argv(fork_path, branch)
    return {
      argv = { GIT, "-C", tostring(fork_path), "push", "origin", tostring(branch) },
      timeout = 120,
    }
  end

  function M.intent_body_path(op, dedup_key)
    local rt = M.env_or("FKST_RUNTIME_ROOT", ".")
    return rt .. "/codex-saga-" .. M.safe_segment(op) .. "-" .. M.safe_segment(dedup_key) .. ".md"
  end

  -- A read-only gh fetch. Returns the decoded JSON table, or nil on any failure
  -- (fail-closed: a read we cannot confirm is treated as "no data").
  function M.gh_read(argv_opts, exec)
    local ok, out = pcall(run_argv, argv_opts, exec)
    if not ok or type(out) ~= "table" or out.exit_code ~= 0 then
      return nil
    end
    local ok2, decoded = pcall(json.decode, out.stdout or "")
    if not ok2 or type(decoded) ~= "table" then
      return nil
    end
    return decoded
  end

  -- Push the demo fix branch to the fork (owned plane). Dry-run by default: logs
  -- the intended push and returns the intent with NO real push.
  function M.fork_push_intent(fork_path, branch, dedup_key, exec)
    local mode = M.write_mode()
    log.info(string.format("OUTBOUND mode=%s op=fork-branch-push repo=%s branch=%s",
      mode, tostring(M.fork_repo()), tostring(branch)))
    local intent = { mode = mode, op = "fork-branch-push", branch = branch, fork_path = fork_path }
    if mode ~= "real" then
      log.info("codex-saga dry-run: would push " .. tostring(branch) .. " to the fork (no real push)")
      return intent
    end
    if not M.is_nonempty_string(fork_path) then
      error("codex-saga: fork push requires FKST_FORK_LOCAL_PATH")
    end
    with_lock(M.step_key("fork-push", dedup_key), function()
      local out = run_argv(M.git_fork_push_argv(fork_path, branch), exec)
      intent.exit_code = out.exit_code
    end)
    return intent
  end

  -- Generic write-class egress. In dry-run it logs and RETURNS a recorded intent
  -- with NO external mutation (the default). In real mode it takes a process lock,
  -- re-derives the bot-authored marker (skips when already present), writes the
  -- body+marker to a temp file, performs the gh/git call via the argv adapter, and
  -- leaves a within-runtime cache backstop.
  --
  -- req = {op, repo, dedup_key, body, marker, title?, labels?, argv_builder, exec?,
  --        marker_present?}  where marker_present() re-reads GitHub for the marker.
  function M.egress_write(req)
    local mode = M.write_mode()
    log.info(string.format("OUTBOUND mode=%s op=%s repo=%s dedup_key=%s",
      mode, tostring(req.op), tostring(req.repo), tostring(req.dedup_key)))

    local intent = {
      mode = mode,
      op = req.op,
      repo = req.repo,
      dedup_key = req.dedup_key,
      title = req.title,
      labels = req.labels,
      body = req.body,
      marker = req.marker,
    }

    if mode ~= "real" then
      log.info(string.format("codex-saga dry-run: would %s on %s (no external write)",
        tostring(req.op), tostring(req.repo)))
      return intent
    end

    -- Real posture (never reached during tests; FKST_GITHUB_WRITE stays unset).
    local bot = M.bot_login()
    if bot == nil then
      error("codex-saga: FKST_GITHUB_WRITE=1 requires FKST_GITHUB_BOT_LOGIN")
    end
    with_lock(M.step_key(req.op, req.dedup_key), function()
      if type(req.marker_present) == "function" and req.marker_present() then
        log.info("codex-saga: skip-idempotent marker already present")
        intent.skipped = true
        return
      end
      local body = tostring(req.body) .. "\n\n" .. tostring(req.marker) .. "\n"
      local path = M.intent_body_path(req.op, req.dedup_key)
      file.write(path, body)
      local out = run_argv(req.argv_builder(path), req.exec)
      intent.exit_code = out.exit_code
      intent.stdout = out.stdout
      cache_set(M.step_key(req.op .. "-once", req.dedup_key), "1")
    end)
    return intent
  end
end

return S
