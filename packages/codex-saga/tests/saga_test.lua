-- codex-saga department behavior tests, all in DRY-RUN (FKST_GITHUB_WRITE unset by
-- the hermetic runner). These drive each department's pipeline via run_department and
-- assert the real saga behavior: no real foreign write, gate0 route-out, the HARD
-- invitation precondition, and the wired diagnose->...->open_pr handoffs.
--
-- `tk` is the test kit; the global `t` stays the i18n function.
local core = require("core")
local tk = fkst.test

-- Count raised events whose (possibly namespace-qualified) queue contains `suffix`.
local function raises_of(result, suffix)
  local count = 0
  for _, entry in ipairs(result.raises or {}) do
    if tostring(entry.queue):find(suffix, 1, true) ~= nil then
      count = count + 1
    end
  end
  return count
end

-- The payload of the first raised event whose queue contains `suffix`.
local function raise_payload(result, suffix)
  for _, entry in ipairs(result.raises or {}) do
    if tostring(entry.queue):find(suffix, 1, true) ~= nil then
      return entry.payload
    end
  end
  return nil
end

-- Escape a Lua string for embedding inside a JSON string literal (tests build gh
-- read fixtures without a json encoder).
local function json_escape(s)
  return (tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"))
end

local function candidate_ref()
  return { kind = "external", ref = "openai/codex#issues/1234" }
end

return {
  -- ---- pure helpers ---------------------------------------------------------
  -- step_key sanitizes the dedup_key into a valid runtime-key path segment (the raw
  -- dedup_key carries ':' / '#' / '/', which with_lock()/once() reject).
  test_step_key_is_a_valid_runtime_key = function()
    tk.eq(core.step_key("engage", "openai/codex#1234"), "codex-saga/engage/openai_codex_1234")
  end,

  test_parse_entity_ref_extracts_repo_and_number = function()
    local parsed = core.parse_entity_ref(candidate_ref())
    tk.eq(parsed.repo, "openai/codex")
    tk.eq(parsed.number, "1234")
  end,

  -- ---- diagnose -------------------------------------------------------------
  -- No fork checkout configured -> drop to needs_info with a WHY, no raise.
  test_diagnose_needs_info_without_fork = function()
    local result = tk.run_department("departments/diagnose/main.lua", {
      queue = "codex-triage.codex_candidate",
      payload = {
        schema = "codex-triage.candidate.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
        score = 0.73,
      },
    }, { env = { FKST_FORK_LOCAL_PATH = "" } })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_diagnosed"), 0)
  end,

  -- With a fork checkout + a reproducing codex run, advance to codex_diagnosed.
  test_diagnose_reproduces_and_advances = function()
    tk.mock_command("worktree add", { stdout = "" })
    tk.mock_command("codex exec", { stdout = "REPRODUCED: yes\nROOT_CAUSE: src/exec/mod.rs:88" })
    tk.mock_command("worktree remove", { stdout = "" })
    local result = tk.run_department("departments/diagnose/main.lua", {
      queue = "codex-triage.codex_candidate",
      payload = {
        schema = "codex-triage.candidate.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
        score = 0.73,
        labels = { "bug" },
      },
    }, { env = { FKST_FORK_LOCAL_PATH = "/tmp/codex-saga-fakefork" } })
    tk.eq(result.exit_code, 0)
    tk.is_true(raises_of(result, "codex_diagnosed") >= 1)
  end,

  -- Not reproduced -> drop to needs_info (no raise) AND durably record the terminal drop
  -- so the dashboard scoreboard/funnel reflects the attempt. The append is local +
  -- UNCONDITIONAL (dry-run-safe, NO foreign write); disposition inert to codex-learn.
  test_diagnose_not_reproduced_records_drop = function()
    local outcomes_path = (os.getenv("FKST_RUNTIME_ROOT") or ".") .. "/saga-diagnose-drop.jsonl"
    tk.mock_command("worktree add", { stdout = "" })
    tk.mock_command("codex exec", { stdout = "REPRODUCED: no" })
    tk.mock_command("worktree remove", { stdout = "" })
    local result = tk.run_department("departments/diagnose/main.lua", {
      queue = "codex-triage.codex_candidate",
      payload = {
        schema = "codex-triage.candidate.v1",
        dedup_key = "codex-triage:candidate:openai/codex#16205",
        source_ref = { kind = "external", ref = "openai/codex#issues/16205" },
        score = 0.89,
        labels = { "bug", "regression" },
      },
    }, { env = {
      FKST_FORK_LOCAL_PATH = "/tmp/codex-saga-fakefork",
      FKST_LEARNING_OUTCOMES_PATH = outcomes_path,
    } })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_diagnosed"), 0)
    -- the drop is retrievable from the durable channel: state=needs_info, WHY=not_reproduced.
    local latest = core.latest_outcome_by_dedup(core.read_outcomes({ path = outcomes_path }))
    local rec = latest["codex-triage:candidate:openai/codex#16205"]
    tk.eq(rec.state, "needs_info")
    tk.eq(rec.reason, "not_reproduced")
    tk.eq(rec.disposition, "dropped") -- inert to codex-learn's resolved set
    tk.eq(rec.type, "regression") -- classify_type precedence: regression beats bug
  end,

  -- ---- implement (WRITE-CLASS fix step) -------------------------------------
  -- No fork checkout configured -> drop to needs_info with a WHY, no raise.
  test_implement_needs_info_without_fork = function()
    local result = tk.run_department("departments/implement/main.lua", {
      queue = "codex_diagnosed",
      payload = {
        schema = "codex-saga.diagnosed.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
        root_cause = "codex-rs/exec/mod.rs:88",
        labels = { "exec", "bug" },
        score = 0.73,
      },
    }, { env = { FKST_FORK_LOCAL_PATH = "" } })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_implemented"), 0)
  end,

  -- Dry-run: retrieves exemplars (from the PR-style fixture), resolves the crate
  -- (from the repo-structure fixture), and advances to codex_implemented carrying
  -- exemplar refs - WITHOUT running any real command (no codex/git write).
  test_implement_dry_run_retrieves_and_advances = function()
    local result = tk.run_department("departments/implement/main.lua", {
      queue = "codex_diagnosed",
      payload = {
        schema = "codex-saga.diagnosed.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
        root_cause = "codex-cli/src/utils/agent/agent-loop.ts:42",
        labels = { "exec", "bug" },
        score = 0.73,
      },
    }, { env = {
      FKST_FORK_LOCAL_PATH = "/tmp/codex-saga-fakefork",
      FKST_PR_STYLE_CORPUS = "data/fixtures/corpus_pr_style.fixture.jsonl",
      FKST_REPO_STRUCTURE = "data/fixtures/repo_structure.fixture.json",
    } })
    tk.eq(result.exit_code, 0)
    tk.is_true(raises_of(result, "codex_implemented") >= 1)
    -- the defining dry-run assertion: ZERO real commands (no codex/git write).
    tk.eq(#tk.command_calls(), 0)
    local payload = raise_payload(result, "codex_implemented")
    tk.is_true(type(payload.exemplars_used) == "table")
    tk.is_true(#payload.exemplars_used >= 1)
    tk.eq(payload.picked_score, 0.73)
  end,

  -- ---- dossier --------------------------------------------------------------
  -- FIX A: dossier RETRIEVES engagement exemplars via precedent.tfidf over the
  -- engagement corpus (fixture injected), carries the refs, and folds them into
  -- exemplars_used for credit assignment - all in dry-run with no command.
  test_dossier_builds_and_advances_dry_run = function()
    local result = tk.run_department("departments/dossier/main.lua", {
      queue = "codex_implemented",
      payload = {
        schema = "codex-saga.implemented.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
        root_cause = "src/exec/mod.rs:88",
        labels = { "bug" },
        demo_branch = "codex-saga/fix-openai-codex-1234",
        exemplars_used = { "openai/codex#178" },
        picked_score = 0.73,
      },
    }, { env = { FKST_ENGAGEMENT_CORPUS = "data/fixtures/corpus_engagement.fixture.jsonl" } })
    tk.eq(result.exit_code, 0)
    tk.is_true(raises_of(result, "codex_dossier") >= 1)
    -- dry-run: NO real fork push (no exec_argv command performed).
    tk.eq(#tk.command_calls(), 0)
    -- the learning metadata is threaded forward toward track.
    local payload = raise_payload(result, "codex_dossier")
    tk.eq(payload.demo_branch, "codex-saga/fix-openai-codex-1234")
    -- retrieval-conditioned engagement learning: exemplar refs retrieved + folded in.
    tk.is_true(type(payload.engagement_exemplars) == "table")
    tk.is_true(#payload.engagement_exemplars >= 1)
    tk.is_true(#payload.exemplars_used >= 2) -- implement PR exemplar + engagement ones
  end,

  -- ---- gate -----------------------------------------------------------------
  -- gate0: a security-labeled item is routed out privately and dropped.
  test_gate0_security_routes_out_and_drops = function()
    local result = tk.run_department("departments/gate/main.lua", {
      queue = "codex_dossier",
      payload = {
        schema = "codex-saga.dossier.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
        root_cause = "src/exec/mod.rs:88",
        labels = { "bug", "security" },
      },
    })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_cleared"), 0)
  end,

  -- A clean item with unanimous round-1 consensus (all THREE angles) clears the gate.
  test_gate_clean_pass_clears = function()
    -- Durable engagement count must be determinable (0 today) to pass the cap.
    tk.mock_command("gh issue list", { stdout = "[]" })
    tk.mock_command("codex exec", { stdout = "VERDICT: approve\nRATIONALE: aligned." })
    tk.mock_command("codex exec", { stdout = "VERDICT: approve\nRATIONALE: scoped." })
    tk.mock_command("codex exec", { stdout = "VERDICT: approve\nRATIONALE: plan is sound." })
    local result = tk.run_department("departments/gate/main.lua", {
      queue = "codex_dossier",
      payload = {
        schema = "codex-saga.dossier.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
        root_cause = "src/exec/mod.rs:88",
        labels = { "bug" },
      },
    })
    tk.eq(result.exit_code, 0)
    tk.is_true(raises_of(result, "codex_cleared") >= 1)
  end,

  -- consensus refusal drops with a WHY (no clear) AND durably records the advocate
  -- refusal + per-angle verdicts + ROUND signals to the outcomes channel (retrievable
  -- in dry-run; NO foreign write). With no codex mocks every judge fails CLOSED to
  -- reject; two consecutive all-reject rounds exit early as a STABLE unanimous reject.
  test_gate_consensus_refusal_drops = function()
    local delib_path = (os.getenv("FKST_RUNTIME_ROOT") or ".") .. "/saga-gate-consensus-refuse.jsonl"
    tk.mock_command("gh issue list", { stdout = "[]" })
    local result = tk.run_department("departments/gate/main.lua", {
      queue = "codex_dossier",
      payload = {
        schema = "codex-saga.dossier.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
        root_cause = "src/exec/mod.rs:88",
        labels = { "bug" },
      },
    }, { env = { FKST_LEARNING_OUTCOMES_PATH = delib_path } })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_cleared"), 0)
    -- the refusal is now retrievable from the durable channel: the "best stat" survives.
    local latest = core.latest_outcome_by_dedup(core.read_outcomes({ path = delib_path }))
    local rec = latest["codex-triage:candidate:openai/codex#1234"]
    tk.eq(rec.disposition, "refused_consensus")
    tk.eq(rec.consensus_angles.alignment, "reject") -- fail-closed judges
    tk.eq(rec.consensus_angles.approach, "reject") -- the third (defence) angle
    tk.eq(rec.consensus_rounds, 2) -- stable unanimous reject exits at round 2
    tk.eq(rec.converge_mode, "rejected")
    tk.eq(rec.deliberation_count, 7) -- 2 rounds x 3 angles + the dissent
  end,

  -- A clean gate PASS durably records a "cleared" milestone (symmetric with the refusal
  -- path) so the dashboard funnel's cleared/engaged stats are retrievable in dry-run. The
  -- record carries the per-angle deliberation + verdict=pass; disposition is inert to codex-learn.
  test_gate_pass_records_cleared = function()
    local cleared_path = (os.getenv("FKST_RUNTIME_ROOT") or ".") .. "/saga-gate-pass-cleared.jsonl"
    tk.mock_command("gh issue list", { stdout = "[]" })
    tk.mock_command("codex exec", { stdout = "VERDICT: approve\nRATIONALE: aligned." })
    tk.mock_command("codex exec", { stdout = "VERDICT: approve\nRATIONALE: scoped." })
    tk.mock_command("codex exec", { stdout = "VERDICT: approve\nRATIONALE: plan is sound." })
    local result = tk.run_department("departments/gate/main.lua", {
      queue = "codex_dossier",
      payload = {
        schema = "codex-saga.dossier.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
        root_cause = "src/exec/mod.rs:88",
        labels = { "bug" },
      },
    }, { env = { FKST_LEARNING_OUTCOMES_PATH = cleared_path } })
    tk.eq(result.exit_code, 0)
    tk.is_true(raises_of(result, "codex_cleared") >= 1)
    local rec = core.latest_outcome_by_dedup(core.read_outcomes({ path = cleared_path }))["codex-triage:candidate:openai/codex#1234"]
    tk.eq(rec.disposition, "cleared") -- inert to codex-learn's resolved set
    tk.eq(rec.state, "engage")
    tk.eq(rec.advocate_verdict, "pass")
    tk.eq(rec.deliberation_count, 4) -- 1 round x 3 consensus angles + the dissent
    tk.eq(rec.consensus_rounds, 1) -- unanimous round-1 approval converges immediately
    tk.eq(rec.converge_mode, "unanimous")
  end,

  -- FIX 3: the volume cap is DURABLE and MARKER-TRUTH. With cap-many bot-authored,
  -- MARKER-BEARING engagement records today on the tracker (and an EMPTY runtime
  -- cache, as after a restart), the gate drops with the volume-cap WHY.
  test_gate_drops_when_durable_engagement_cap_reached = function()
    local function record(n)
      local dedup = "codex-triage:candidate:openai/codex#" .. n
      return '{"author":{"login":"codex-bot"},"body":"' .. json_escape(core.control_marker(dedup)) .. '"}'
    end
    tk.mock_command("gh issue list", {
      stdout = "[" .. record("11") .. "," .. record("12") .. "," .. record("13") .. "]",
    })
    local result = tk.run_department("departments/gate/main.lua", {
      queue = "codex_dossier",
      payload = {
        schema = "codex-saga.dossier.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
        root_cause = "src/exec/mod.rs:88",
        labels = { "bug" },
      },
    }, { env = { FKST_GITHUB_BOT_LOGIN = "codex-bot" } })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_cleared"), 0)
  end,

  -- FIX 3 follow-up: bot-authored issues that carry the engaged LABEL but NO
  -- engagement marker in their body do NOT count toward the cap (marker truth, not
  -- label shape). Three such records + approving consensus -> the gate still CLEARS,
  -- proving they were not counted.
  test_gate_markerless_engaged_records_do_not_count = function()
    tk.mock_command("gh issue list", {
      stdout = '[{"author":{"login":"codex-bot"},"body":"engaged but no marker"},'
        .. '{"author":{"login":"codex-bot"},"body":"also no marker"},'
        .. '{"author":{"login":"codex-bot"},"body":"still none"}]',
    })
    tk.mock_command("codex exec", { stdout = "VERDICT: approve\nRATIONALE: aligned." })
    tk.mock_command("codex exec", { stdout = "VERDICT: approve\nRATIONALE: scoped." })
    tk.mock_command("codex exec", { stdout = "VERDICT: approve\nRATIONALE: plan is sound." })
    local result = tk.run_department("departments/gate/main.lua", {
      queue = "codex_dossier",
      payload = {
        schema = "codex-saga.dossier.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
        root_cause = "src/exec/mod.rs:88",
        labels = { "bug" },
      },
    }, { env = { FKST_GITHUB_BOT_LOGIN = "codex-bot" } })
    tk.eq(result.exit_code, 0)
    tk.is_true(raises_of(result, "codex_cleared") >= 1)
  end,

  -- FIX 3 corollary: an undeterminable durable count fails closed (drop).
  test_gate_fails_closed_when_durable_count_unknown = function()
    local result = tk.run_department("departments/gate/main.lua", {
      queue = "codex_dossier",
      payload = {
        schema = "codex-saga.dossier.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
        root_cause = "src/exec/mod.rs:88",
        labels = { "bug" },
      },
    })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_cleared"), 0)
  end,

  -- ---- engage ---------------------------------------------------------------
  -- An unverified payload (the current dry-run posture: no real validation, no pushed
  -- branch) is REFUSED to post and the refusal is TERMINAL: NO foreign write AND NO
  -- codex_engaged, so the saga never advances into invite/PR handling without a
  -- substantiated public post (integrated Codex review P1).
  test_engage_dry_run_no_foreign_write = function()
    local result = tk.run_department("departments/engage/main.lua", {
      queue = "codex_cleared",
      payload = {
        schema = "codex-saga.cleared.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
        root_cause = "src/exec/mod.rs:88",
        labels = { "bug" },
        score = 0.73,
      },
    })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_engaged"), 0) -- terminal refuse-to-post: no advance
    -- The defining dry-run assertion: NO real gh/git write was performed.
    tk.eq(#tk.command_calls(), 0)
  end,

  -- ---- invite_watch ---------------------------------------------------------
  test_invite_watch_tick_without_invite_does_not_raise = function()
    local result = tk.run_department("departments/invite_watch/main.lua", {
      queue = "codex_invite_watch_tick",
      payload = {},
    })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_invited"), 0)
  end,

  test_invite_watch_engaged_without_invite_does_not_raise = function()
    local result = tk.run_department("departments/invite_watch/main.lua", {
      queue = "codex_engaged",
      payload = {
        schema = "codex-saga.engaged.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
      },
    })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_invited"), 0)
  end,

  test_invite_watch_engaged_with_maintainer_invite_raises = function()
    -- An invite = a maintainer response AFTER our bot engage comment on the upstream thread.
    tk.mock_command("gh issue view", { stdout = '{"assignees":[],"comments":['
      .. '{"author":{"login":"codex-bot"},"authorAssociation":"NONE","body":"'
      .. json_escape(core.engage_marker("codex-triage:candidate:openai/codex#1234")) .. '"},'
      .. '{"author":{"login":"gpeal"},"authorAssociation":"MEMBER","body":"please open a PR"}'
      .. ']}' })
    local result = tk.run_department("departments/invite_watch/main.lua", {
      queue = "codex_engaged",
      payload = {
        schema = "codex-saga.engaged.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
        control_issue = "7",
      },
    }, { env = { FKST_GITHUB_BOT_LOGIN = "codex-bot" } })
    tk.eq(result.exit_code, 0)
    tk.is_true(raises_of(result, "codex_invited") >= 1)
  end,

  -- FIX 2: the cron-tick invite path raises codex_invited carrying the ORIGINAL
  -- openai/codex candidate source_ref (re-derived from the control issue's source
  -- marker), NOT the harness tracker issue.
  test_invite_watch_tick_preserves_original_source_ref = function()
    local dedup = "codex-triage:candidate:openai/codex#1234"
    local original_ref = "openai/codex#issues/1234"
    local body = core.control_marker(dedup) .. "\n"
      .. core.source_marker(dedup, { kind = "external", ref = original_ref })
    tk.mock_command("gh issue list", {
      stdout = '[{"number":7,"author":{"login":"codex-bot"},"body":"' .. json_escape(body) .. '"}]',
    })
    tk.mock_command("gh issue view", { stdout = '{"assignees":[],"comments":['
      .. '{"author":{"login":"codex-bot"},"authorAssociation":"NONE","body":"'
      .. json_escape(core.engage_marker(dedup)) .. '"},'
      .. '{"author":{"login":"gpeal"},"authorAssociation":"MEMBER","body":"please open a PR"}'
      .. ']}' })
    local result = tk.run_department("departments/invite_watch/main.lua", {
      queue = "codex_invite_watch_tick",
      payload = {},
    }, { env = { FKST_GITHUB_BOT_LOGIN = "codex-bot" } })
    tk.eq(result.exit_code, 0)
    tk.is_true(raises_of(result, "codex_invited") >= 1)
    local payload = raise_payload(result, "codex_invited")
    tk.eq(payload.source_ref.ref, original_ref)
    tk.eq(payload.control_issue, "7")
  end,

  -- ---- open_pr --------------------------------------------------------------
  -- HARD precondition: no recorded invite -> REFUSE (no codex_proposed).
  test_open_pr_refuses_without_invite = function()
    local result = tk.run_department("departments/open_pr/main.lua", {
      queue = "codex_invited",
      payload = {
        schema = "codex-saga.invited.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
      },
    })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_proposed"), 0)
  end,

  -- FIX 1: open_pr is the LAST safety boundary. Even with FKST_PROPOSE_REQUIRE_INVITE
  -- disabled, with NO recorded invite it must STILL refuse (zero codex_proposed) -
  -- no env flag can relax the no-uninvited-PR boundary.
  test_open_pr_refuses_uninvited_even_when_policy_disabled = function()
    local result = tk.run_department("departments/open_pr/main.lua", {
      queue = "codex_invited",
      payload = {
        schema = "codex-saga.invited.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
      },
    }, { env = { FKST_PROPOSE_REQUIRE_INVITE = "0" } })
    tk.eq(result.exit_code, 0)
    tk.eq(raises_of(result, "codex_proposed"), 0)
  end,

  -- With a re-derived maintainer invite, open the PR (dry-run) and advance, carrying
  -- the learning metadata to track.
  test_open_pr_proceeds_with_invite_dry_run = function()
    tk.mock_command("gh issue view", { stdout = '{"assignees":[],"comments":['
      .. '{"author":{"login":"codex-bot"},"authorAssociation":"NONE","body":"'
      .. json_escape(core.engage_marker("codex-triage:candidate:openai/codex#1234")) .. '"},'
      .. '{"author":{"login":"bolinfest"},"authorAssociation":"MEMBER","body":"please open a PR"}'
      .. ']}' })
    local result = tk.run_department("departments/open_pr/main.lua", {
      queue = "codex_invited",
      payload = {
        schema = "codex-saga.invited.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
        control_issue = "7",
        demo_branch = "codex-saga/fix-openai-codex-1234",
        exemplars_used = { "openai/codex#178" },
        picked_score = 0.73,
        advocate_verdict = "pass",
        root_cause_verified = true,
      },
    }, { env = { FKST_GITHUB_BOT_LOGIN = "codex-bot" } })
    tk.eq(result.exit_code, 0)
    tk.is_true(raises_of(result, "codex_proposed") >= 1)
    local payload = raise_payload(result, "codex_proposed")
    tk.eq(payload.advocate_verdict, "pass")
    tk.is_true(type(payload.exemplars_used) == "table")
  end,

  -- ---- track (TERMINAL recorder) --------------------------------------------
  -- track appends the initial outcome to the durable JSONL + mirrors it as a (dry-run)
  -- control-issue comment, and raises the NEW TERMINAL queue codex_tracked. The
  -- durable path override keeps the append parent-dir present (no real mkdir).
  test_track_records_outcome_and_raises_tracked = function()
    local outcomes_path = (os.getenv("FKST_RUNTIME_ROOT") or ".") .. "/saga-track-outcomes.jsonl"
    local result = tk.run_department("departments/track/main.lua", {
      queue = "codex_proposed",
      payload = {
        schema = "codex-saga.proposed.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
        control_issue = "7",
        picked_score = 0.73,
        exemplars_used = { "openai/codex#178", "openai/codex#1" },
        advocate_verdict = "pass",
        advocate_reason = "approved",
      },
    }, { env = { FKST_LEARNING_OUTCOMES_PATH = outcomes_path } })
    tk.eq(result.exit_code, 0)
    tk.is_true(raises_of(result, "codex_tracked") >= 1)
    -- the visible GitHub mirror is dry-run + the durable append is a local file:
    -- NO real network/egress command.
    tk.eq(#tk.command_calls(), 0)
    local payload = raise_payload(result, "codex_tracked")
    tk.eq(payload.advocate_verdict, "pass")
  end,
}
