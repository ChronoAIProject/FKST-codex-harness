-- core.progress: early-adopt of the saga control issue + per-stage progress feed.
--
-- The control issue on the harness tracker is created the moment the saga ADOPTS a
-- candidate (diagnose entry), and every stage posts a marker-gated progress COMMENT so
-- the tracker is a live activity board, not just an engage-time state mirror. All
-- writes go through core.egress (DRY-RUN by default; real only under FKST_GITHUB_WRITE=1)
-- and are gated on bot-authored GitHub markers (the durable idempotency truth), so a
-- transition posts at most once. The tracker is the OWNED plane, so this is NOT a
-- two-plane concern - only openai/codex writes stay gated to engage/open_pr.
--
-- Dry-run discipline: every GitHub READ (control_issue_number) is placed INSIDE the
-- egress argv/marker closures (invoked in real mode only) or behind a
-- write_mode()=="real" guard, so a dry-run transition performs ZERO commands.
--
-- Terminal drops (needs_info/refused) post their WHY as a comment but leave the control
-- issue OPEN: the locator + cap scans are `--state open`, so closing a control issue
-- would make its marker invisible (duplicate re-creation + cap under-count). Issues stay
-- open with the terminal comment; bulk-close is a later, scan-aware enhancement.
local S = {}

-- Marker-safety bound for the saga `state` embedded in a state marker (all call sites
-- pass code literals from the saga state set; this is defense-in-depth).
local STATE_LIMIT = 64

-- Saga state -> the SINGLE swappable board label (numbered pipeline phase while in
-- flight, a colored terminal tag once settled). Several states share a phase (the label
-- flips when the NEXT phase completes). `candidate` and `engaged` are STICKY separate
-- labels and NEVER swap-removed: `candidate` is the claim locator, and the volume cap +
-- invite/outcome scans key off state_label("engaged").
-- NOTE: the terminal suffixes are MIRRORED in codex-triage's REMOTE_FINAL_STAGES (the
-- cross-substrate claim parser); change them together.
local STATE_PHASE_LABEL = {
  diagnosing = "1/6-diagnose",
  diagnosed = "1/6-diagnose",
  implemented = "2/6-implement",
  dossier = "3/6-dossier",
  cleared = "4/6-gate",
  engaged = "5/6-engage",
  invited = "5/6-engage",
  proposed = "6/6-propose",
  -- terminal tags (colored on the tracker: rejected red, merged green, needs-info amber).
  -- The full saga-table terminal set is covered (incl. blocked/security_routed/
  -- needs_invite) so any recorded terminal settles the cross-substrate claim.
  needs_info = "needs-info",
  refused = "rejected",
  tracked = "tracked",
  merged = "merged",
  closed = "closed",
  blocked = "blocked",
  security_routed = "security-routed",
  needs_invite = "needs-invite",
}

-- Priority tag thresholds over the 0-100 rubric score (green high / red low).
local PRIO_HIGH = 80
local PRIO_MID = 65

function S.install(M)
  -- Stable locator label: present from adopt through terminal, never removed, so the
  -- progress feed can re-derive the control issue number at any stage. Distinct from
  -- the engage-time `engaged` label the volume cap + invite/outcome scans key off.
  function M.candidate_label()
    return M.state_label("candidate")
  end

  -- The board label for a saga state ("codex-saga:1/6-diagnose", "codex-saga:rejected"),
  -- or nil for states with no board phase.
  function M.phase_label(state)
    local suffix = STATE_PHASE_LABEL[tostring(state or "")]
    if suffix == nil then
      return nil
    end
    return M.state_label(suffix)
  end

  -- All DISTINCT phase/terminal labels (the swap-remove set for set_state_label).
  local function all_phase_labels()
    local seen, out = {}, {}
    for _, suffix in pairs(STATE_PHASE_LABEL) do
      if not seen[suffix] then
        seen[suffix] = true
        out[#out + 1] = M.state_label(suffix)
      end
    end
    table.sort(out) -- deterministic argv for tests/idempotency
    return out
  end

  -- Score-tier priority tag, colored on the tracker (green high / amber mid / red low).
  -- Set ONCE at claim time; never swapped. nil score -> no tag. Scale-robust for 0-1
  -- rubric scores (normalized onto 0-100).
  function M.priority_label(score)
    local n = tonumber(score)
    if n == nil then
      return nil
    end
    if n <= 1 then
      n = n * 100
    end
    if n >= PRIO_HIGH then
      return M.state_label("prio-high")
    end
    if n >= PRIO_MID then
      return M.state_label("prio-mid")
    end
    return M.state_label("prio-low")
  end

  -- NOTE: adoption is UNCONDITIONAL (no score gate): the control issue is the
  -- cross-substrate claim ledger (codex-triage reads the tracker's open control
  -- issues to know which candidates are taken), and a claim that is not on GitHub
  -- is not a claim. Diagnose ensures the issue before any expensive work.

  -- `state` is validated marker-safe before it is embedded in a state marker (which
  -- itself only validates the dedup_key). Fail-loud on an unsafe state.
  local function assert_state(state)
    if not M.is_marker_safe(state, STATE_LIMIT) then
      error("codex-saga: unsafe saga state for marker: " .. tostring(state))
    end
  end

  -- Locate the OPEN control issue number by the stable candidate label + control marker
  -- (bot-authored trust). Returns a string number or nil. This is a REAL-mode gh READ;
  -- callers keep it inside egress closures / write_mode guards so dry-run never runs it.
  function M.control_issue_number(dedup_key, exec)
    local list = M.gh_read(M.gh_issue_list_argv(M.tracker_repo(), M.candidate_label(), "number,body,author"), exec)
    if type(list) ~= "table" then
      return nil
    end
    local marker = M.control_marker(dedup_key)
    local bot = M.bot_login()
    for _, issue in ipairs(list) do
      if M.trusted_marker(issue, marker, bot) then
        return tostring(issue.number)
      end
    end
    return nil
  end

  -- Adopt: idempotently create the control issue on the tracker with the stable
  -- candidate label + the control/state/source markers (control_body). Dry-run logs the
  -- intent and returns with no external write; real mode skips when the marker is
  -- already present (re-derived from GitHub via control_issue_number).
  -- ctx carries the small adopt-time arguments {score, area_labels, type} rendered into
  -- the visible body. The issue is created with the stable `candidate` label + the initial
  -- numbered phase label (later swapped by set_state_label) + the score-tier priority tag.
  function M.ensure_control_issue(dedup_key, source_ref, state, ctx)
    state = state or "diagnosing"
    assert_state(state)
    ctx = ctx or {}
    local create_labels = { M.candidate_label() }
    local phase = M.phase_label(state)
    if phase ~= nil then
      create_labels[#create_labels + 1] = phase
    end
    local prio = M.priority_label(ctx.score)
    if prio ~= nil then
      create_labels[#create_labels + 1] = prio
    end
    return M.egress_write({
      op = "control-issue-create",
      repo = M.tracker_repo(),
      dedup_key = dedup_key,
      title = M.control_title(dedup_key),
      labels = create_labels,
      body = M.control_body(dedup_key, state, source_ref, ctx),
      marker = M.control_marker(dedup_key),
      argv_builder = function(path)
        return M.gh_issue_create_argv(M.tracker_repo(), M.control_title(dedup_key), path, create_labels)
      end,
      marker_present = function()
        return M.control_issue_number(dedup_key) ~= nil
      end,
    })
  end

  -- Reflect the CURRENT board phase as a single swapped label: add the state's phase/
  -- terminal label and remove every OTHER phase/terminal label (never the sticky
  -- candidate/engaged locators or the prio-* tags). Dry-run-safe: returns the intent
  -- WITHOUT any command (real writes only under FKST_GITHUB_WRITE=1).
  function M.set_state_label(dedup_key, state, control_issue, exec)
    local mode = M.write_mode()
    local intent = { mode = mode, op = "state-label", dedup_key = dedup_key, state = state }
    local target = M.phase_label(state)
    if target == nil then
      intent.skipped = true -- state has no board phase; nothing to swap
      return intent
    end
    if mode ~= "real" then
      return intent
    end
    local number = control_issue or M.control_issue_number(dedup_key, exec)
    if number == nil then
      intent.skipped = true
      return intent
    end
    local remove = {}
    for _, label in ipairs(all_phase_labels()) do
      if label ~= target then
        remove[#remove + 1] = label
      end
    end
    M.run_argv(M.gh_issue_edit_labels_argv(M.tracker_repo(), tostring(number), { target }, remove), exec)
    return intent
  end

  -- Add the engage-time `engaged` label (idempotent in gh; used by the durable volume
  -- cap + the invite/outcome scans, which key off state_label("engaged")). Dry-run-safe:
  -- returns the recorded intent WITHOUT any command.
  function M.add_engaged_label(dedup_key, control_issue, exec)
    local mode = M.write_mode()
    log.info(string.format("OUTBOUND mode=%s op=engaged-label repo=%s dedup_key=%s",
      mode, tostring(M.tracker_repo()), tostring(dedup_key)))
    local intent = { mode = mode, op = "engaged-label", dedup_key = dedup_key }
    if mode ~= "real" then
      return intent
    end
    local number = control_issue or M.control_issue_number(dedup_key, exec)
    if number == nil then
      intent.skipped = true
      return intent
    end
    -- Capture the command result: a failed `gh issue edit --add-label` must NOT be treated
    -- as success (the label is what the cap + invite/outcome scans key off).
    local out = M.run_argv(M.gh_issue_add_label_argv(M.tracker_repo(), tostring(number), M.state_label("engaged")), exec)
    intent.exit_code = (type(out) == "table") and out.exit_code or nil
    intent.ok = intent.exit_code == 0
    return intent
  end

  -- Parse the created issue number from a gh `issue create` intent's stdout (create
  -- prints the new issue URL, e.g. .../issues/42). Returns a string number or nil.
  function M.issue_number_from_create(intent)
    if type(intent) ~= "table" or not M.is_nonempty_string(intent.stdout) then
      return nil
    end
    return intent.stdout:match("/issues/(%d+)")
  end

  -- Engage-time control issue: ensure it exists, resolve its number RELIABLY (from the
  -- create output when we just made it, else re-derive by marker), and stamp the engaged
  -- label using that resolved number (not a fresh re-locate that could miss a just-created
  -- issue). Returns the number. DRY-RUN returns nil (no external write/read). REAL mode
  -- returns the number, or nil if it could not be established (caller fails closed).
  function M.ensure_engaged(dedup_key, source_ref, ctx)
    local intent = M.ensure_control_issue(dedup_key, source_ref, "engaged", ctx)
    if M.write_mode() ~= "real" then
      return nil
    end
    local number = M.issue_number_from_create(intent) or M.control_issue_number(dedup_key)
    if number == nil then
      return nil
    end
    -- Fail closed if the engaged label could not be applied: returning nil makes engage
    -- hard-fail BEFORE the upstream comment, so we never post an engagement the cap +
    -- invite/outcome scans (which key off the engaged label) cannot see.
    local labeled = M.add_engaged_label(dedup_key, number)
    if not labeled.ok then
      log.warn("codex-saga/progress: could not apply the engaged label to control issue "
        .. tostring(number) .. "; failing closed")
      return nil
    end
    return number
  end

  -- Human progress line for a state (locale-driven) + small carried scalars. The state
  -- marker (idempotency) is appended by core.egress, never here.
  function M.progress_body(dedup_key, state, ctx)
    ctx = ctx or {}
    local lines = { t("codex-saga.progress." .. tostring(state)) }
    if M.is_nonempty_string(ctx.root_cause) then
      lines[#lines + 1] = "root_cause: " .. tostring(ctx.root_cause)
    end
    if M.is_nonempty_string(ctx.reason) then
      lines[#lines + 1] = "reason: " .. tostring(ctx.reason)
    end
    if M.is_nonempty_string(ctx.detail) then
      lines[#lines + 1] = tostring(ctx.detail)
    end
    return table.concat(lines, "\n")
  end

  -- Post a marker-gated progress COMMENT for `state` on the control issue (dry-run by
  -- default). Idempotent per (dedup_key, state) via the state marker. ctx.control_issue
  -- is an optional carried locator. In real mode the locator is resolved ONCE up front;
  -- if the control issue cannot be located we fail closed (skip) rather than commenting
  -- on issue "". Dry-run never resolves the locator (no GitHub read, no command).
  function M.record_transition(dedup_key, state, ctx)
    ctx = ctx or {}
    assert_state(state)
    local number = ctx.control_issue
    if number == nil and M.write_mode() == "real" then
      number = M.control_issue_number(dedup_key)
      if number == nil then
        log.warn("codex-saga/progress: no control issue located for " .. tostring(dedup_key)
          .. "; skipping progress for state=" .. tostring(state))
        return { mode = "real", op = "progress-" .. tostring(state), skipped = true }
      end
    end
    local intent = M.egress_write({
      op = "progress-" .. tostring(state),
      repo = M.tracker_repo(),
      dedup_key = dedup_key,
      body = M.progress_body(dedup_key, state, ctx),
      marker = M.state_marker(dedup_key, state),
      argv_builder = function(path)
        return M.gh_issue_comment_argv(M.tracker_repo(), tostring(number), path)
      end,
      marker_present = function()
        local bot = M.bot_login()
        local view = M.gh_read(M.gh_issue_view_argv(M.tracker_repo(), tostring(number), "comments"))
        if type(view) ~= "table" then
          return false
        end
        local marker = M.state_marker(dedup_key, state)
        for _, comment in ipairs(view.comments or {}) do
          if M.trusted_marker(comment, marker, bot) then
            return true
          end
        end
        return false
      end,
    })
    -- Reflect the current stage as a swapped label (real mode only; number resolved above).
    if M.write_mode() == "real" and number ~= nil then
      M.set_state_label(dedup_key, state, number)
    end
    return intent
  end
end

return S
