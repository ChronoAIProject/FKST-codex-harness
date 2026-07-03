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
  -- CLOSED as done (close-on-terminal board semantics). limit defaults to 200 (an
  -- explicit page size, never the gh CLI default of 30); callers that must detect
  -- truncation compare the result count against the limit they passed.
  function M.gh_issue_list_argv(repo, label, fields, state, limit)
    return {
      argv = { GH, "issue", "list", "--repo", tostring(repo), "--label", tostring(label),
        "--state", tostring(state or "open"), "--limit", tostring(limit or 200),
        "--json", fields or "number,title,labels" },
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

  -- ---- comment-diversity gate (#3) --------------------------------------------
  -- The only pre-existing idempotency is a per-dedup_key marker on the SAME issue.
  -- Nothing stopped the harness posting the SAME boilerplate across MANY different
  -- issues (the "6 near-identical comments" look). These pure helpers compare a
  -- rendered body against recently-posted harness comment bodies and REFUSE a
  -- near-identical post. Bodies are compared as token SETS (marker/HTML noise is
  -- naturally excluded by the tokenizer), so the gate is robust to trivial edits.

  -- Normalized token SET of a rendered body (lowercased word-ish runs). Also accepts a
  -- single-line fingerprint (see M.body_fingerprint), which re-tokenizes to itself.
  function M.body_tokens(body)
    local set = {}
    for tok in tostring(body or ""):lower():gmatch("[%w][%w_/%.#%-]*") do
      if #tok >= 2 then
        set[tok] = true
      end
    end
    return set
  end

  -- A single-line, marker-safe fingerprint of a body: its unique tokens, sorted and
  -- space-joined. Stored one-per-line in the recent-body ring so multi-line bodies need
  -- no record separator, and re-tokenizes to the same set for similarity.
  function M.body_fingerprint(body)
    local set = M.body_tokens(body)
    local toks = {}
    for tok in pairs(set) do
      toks[#toks + 1] = tok
    end
    table.sort(toks)
    return table.concat(toks, " ")
  end

  -- Jaccard similarity over two token SETS: |A∩B| / |A∪B| in [0,1]. Two empty sets
  -- are treated as dissimilar (0), so an empty body never trips the duplicate gate.
  function M.token_jaccard(a, b)
    local inter, union = 0, 0
    for tok in pairs(a or {}) do
      union = union + 1
      if (b or {})[tok] then
        inter = inter + 1
      end
    end
    for tok in pairs(b or {}) do
      if (a or {})[tok] == nil then
        union = union + 1
      end
    end
    if union == 0 then
      return 0
    end
    return inter / union
  end

  function M.body_similarity(a, b)
    return M.token_jaccard(M.body_tokens(a), M.body_tokens(b))
  end

  -- Similarity at/above which two harness comments are "near-identical boilerplate".
  -- Conservative default (0.9); host-overridable via FKST_ENGAGE_DIVERSITY_THRESHOLD.
  function M.diversity_threshold()
    local v = tonumber(M.read_env("FKST_ENGAGE_DIVERSITY_THRESHOLD"))
    if v ~= nil and v > 0 and v <= 1 then
      return v
    end
    return 0.9
  end

  -- True when `body` is near-identical to ANY recently-posted harness comment body (or
  -- fingerprint). Empty recents -> never a duplicate (fail-open only on genuine absence).
  function M.is_boilerplate_duplicate(body, recent_bodies, threshold)
    threshold = threshold or M.diversity_threshold()
    local tokens = M.body_tokens(body)
    for _, recent in ipairs(recent_bodies or {}) do
      if M.token_jaccard(tokens, M.body_tokens(recent)) >= threshold then
        return true
      end
    end
    return false
  end

  -- Diversity precondition: (ok, reason). Refuses when the rendered body duplicates a
  -- recently-posted harness comment. `recent_bodies` is supplied by the caller (nil/{}
  -- in dry-run, where nothing was posted -> never refuses).
  function M.diversity_ok(body, recent_bodies)
    if M.is_boilerplate_duplicate(body, recent_bodies) then
      return false, t("codex-saga.engage.refuse_duplicate")
    end
    return true
  end

  -- ---- recent-body ring seam (internal; see PM-NEEDS for the durable cross-issue store)
  -- A small per-device ring of the fingerprints of recently-posted engagement bodies,
  -- so the diversity gate has something to compare against WITHOUT a cross-issue GitHub
  -- enumeration. Under the runtime root by default (clearable scratch); host-overridable.
  function M.engage_body_ring_path()
    local override = M.read_env("FKST_ENGAGE_BODY_RING")
    if M.is_nonempty_string(override) then
      return override
    end
    return M.env_or("FKST_RUNTIME_ROOT", ".") .. "/codex-saga-engage-bodies.ring"
  end

  local RING_LIMIT = 50

  function M.recent_engage_bodies(path)
    path = path or M.engage_body_ring_path()
    if not file.exists(path) then
      return {}
    end
    local ok, text = pcall(file.read, path)
    if not ok then
      return {}
    end
    local out = {}
    for line in tostring(text or ""):gmatch("[^\n]+") do
      local fp = M.trim(line)
      if M.is_nonempty_string(fp) then
        out[#out + 1] = fp
      end
    end
    return out
  end

  -- Append a posted body's fingerprint to the ring (called after a REAL post only).
  -- Keeps only the last RING_LIMIT lines so the file stays bounded.
  function M.record_engage_body(body, path)
    path = path or M.engage_body_ring_path()
    local existing = M.recent_engage_bodies(path)
    existing[#existing + 1] = M.body_fingerprint(body)
    local start = 1
    if #existing > RING_LIMIT then
      start = #existing - RING_LIMIT + 1
    end
    local kept = {}
    for i = start, #existing do
      kept[#kept + 1] = existing[i]
    end
    pcall(file.write, path, table.concat(kept, "\n") .. "\n")
  end

  -- Generic write-class egress. In dry-run it logs and RETURNS a recorded intent
  -- with NO external mutation (the default). In real mode it takes a process lock,
  -- re-derives the bot-authored marker (skips when already present), writes the
  -- body+marker to a temp file, performs the gh/git call via the argv adapter, and
  -- leaves a within-runtime cache backstop.
  --
  -- req = {op, repo, dedup_key, body, marker, title?, labels?, argv_builder, exec?,
  --        marker_present?, precondition?}  where marker_present() re-reads GitHub for
  --        the marker and precondition() -> (ok, reason) is a REFUSE-TO-POST integrity
  --        gate (unverified artifacts / boilerplate duplicate) honored in BOTH modes.
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

    -- Refuse-to-post integrity gate (#2/#3/#22): a failing precondition REFUSES the
    -- write in ANY mode (no boilerplate, no unsubstantiated dossier), before we would
    -- log a "would post" intent. The refusal + reason land on the intent for the board.
    if type(req.precondition) == "function" then
      local ok, reason = req.precondition()
      if not ok then
        log.info(string.format("codex-saga: REFUSING %s on %s (refuse-to-post): %s",
          tostring(req.op), tostring(req.repo), tostring(reason)))
        intent.refused = true
        intent.refusal_reason = reason
        return intent
      end
    end

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
