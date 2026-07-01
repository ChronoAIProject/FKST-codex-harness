-- codex-learn/relearn END-TO-END tests via run_department. A full re-derivation cycle
-- runs against INLINE fixtures and writes to a TEMP learning-root under FKST_RUNTIME_ROOT
-- -- it NEVER touches the real committed data/area_rubric.json or data/learning/.
--   (i)  separable corpus -> AUC>=0.70 monotonic -> ACCEPT: rubric + log written.
--   (ii) non-separable corpus -> REJECT: prior rubric preserved, rejection logged WITH
--        candidate_metrics, and the failed cycle is STILL snapshotted.
local t = fkst.test

local function runtime_dir(name)
  local rt = (type(os) == "table" and type(os.getenv) == "function" and os.getenv("FKST_RUNTIME_ROOT")) or "."
  return rt .. "/" .. name
end

local function last_jsonl_row(path)
  local text = file.read(path)
  local last
  for line in text:gmatch("[^\n]+") do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then
      last = trimmed
    end
  end
  return json.decode(last)
end

local function separable_selection()
  return {
    { label = "win", area_labels = { "regression", "exec" }, type = "regression", reactions = 30,
      anatomy_flags = { version = true, repro = true, code = true, os = true, error = true } },
    { label = "win", area_labels = { "bug", "mcp" }, type = "bug", reactions = 20,
      anatomy_flags = { version = true, repro = true, error = true } },
    { label = "win", area_labels = { "bug", "tui" }, type = "bug", reactions = 15,
      anatomy_flags = { version = true, repro = true } },
    { label = "loss", area_labels = { "cli" }, type = "other", reactions = 0, anatomy_flags = {} },
    { label = "loss", area_labels = { "session" }, type = "other", reactions = 0, anatomy_flags = {} },
    { label = "loss", area_labels = { "performance" }, type = "enhancement", reactions = 0, anatomy_flags = {} },
  }
end

local function non_separable_selection()
  return {
    { label = "win", area_labels = { "bug", "exec" }, type = "bug", reactions = 5,
      anatomy_flags = { version = true, repro = true } },
    { label = "loss", area_labels = { "bug", "exec" }, type = "bug", reactions = 5,
      anatomy_flags = { version = true, repro = true } },
    { label = "win", area_labels = { "enhancement" }, type = "enhancement", reactions = 0, anatomy_flags = {} },
    { label = "loss", area_labels = { "enhancement" }, type = "enhancement", reactions = 0, anatomy_flags = {} },
    { label = "win", area_labels = { "cli" }, type = "other", reactions = 0, anatomy_flags = {} },
    { label = "loss", area_labels = { "cli" }, type = "other", reactions = 0, anatomy_flags = {} },
  }
end

local function engagement_fixture()
  return {
    { source_ref = { ref = "openai/codex#101" }, outcome = "merged", maintainer_reactions = 1,
      thread_moves = {
        { role = "author", kind = "opening", len_words = 120 },
        { role = "author", kind = "repro", len_words = 60 },
        { role = "contributor", kind = "offer_to_implement", len_words = 30 },
      } },
  }
end

local function pr_fixture()
  return {
    { source_ref = { ref = "openai/codex#201" }, merged = true, additions = 30, deletions = 5,
      changed_files = 2, commits = 1, has_test = true,
      touched_paths = { "codex-rs/exec/src/lib.rs" }, author_assoc = "CONTRIBUTOR" },
  }
end

return {
  -- (i) ACCEPT: separable corpus + a folded win outcome clears the gate; the published
  -- rubric is updated (prior fields preserved), and snapshot + log are written to TEMP.
  test_accept_writes_rubric_and_log_to_temp_root = function()
    local base = runtime_dir("learn_good")
    local rubric_path = base .. "/area_rubric.json"
    local ts = 1730000000001

    local result = t.run_department("departments/relearn/main.lua", {
      queue = "codex_relearn_tick",
      ts = ts,
      payload = {
        learning_root = base,
        rubric_path = rubric_path,
        corpora = {
          selection = separable_selection(),
          engagement = engagement_fixture(),
          pr_style = pr_fixture(),
        },
        outcomes = {
          -- §5 durable-outcomes shape (codex-saga's writer): a resolved merged attempt.
          { source_ref = { ref = "openai/codex#900" }, dedup_key = "codex-triage:dup:openai/codex#900",
            picked_score = 70, area_labels = { "bug", "exec" }, type = "bug", exemplars_used = {},
            engagement_reaction = "positive", ci = "pass", review_comment_themes = {},
            disposition = "merged", advocate_verdict = "pass", advocate_reason = "" },
        },
        prior_rubric = { _seed = "prior", areas = { exec = { tier = "A_target" } } },
      },
    })
    t.eq(result.exit_code, 0)

    local row = last_jsonl_row(base .. "/relearn_log.jsonl")
    t.eq(row.accepted, true)
    t.eq(row.status, "accepted")
    t.is_true(type(row.auc) == "number" and row.auc >= 0.70)
    t.is_true(type(row.candidate_metrics) == "table")
    t.is_true(type(row.exemplar_rerank_summary) == "table")
    t.is_true(type(row.advocate_calibration_delta) == "table")
    -- the durable §5 outcome was folded into ALL THREE banks (rubric + both styleguides
    -- self-improve from our attempts, not just the bootstrap corpora)
    t.is_true(row.counts_in.folded.selection >= 1)
    t.is_true(row.counts_in.folded.engagement >= 1)
    t.is_true(row.counts_in.folded.pr_style >= 1)

    -- published rubric updated, prior fields preserved
    local rubric = json.decode(file.read(rubric_path))
    t.eq(rubric.selection_model.accepted, true)
    t.eq(rubric._seed, "prior")

    -- ALWAYS-snapshot + styleguides written to the temp root
    t.eq(file.exists(base .. "/rubric_history/area_rubric." .. ts .. ".json"), true)
    t.eq(file.exists(base .. "/engagement_styleguide.md"), true)
    t.eq(file.exists(base .. "/pr_styleguide.md"), true)
  end,

  -- (ii) REJECT: non-separable corpus fails the gate; the prior accepted rubric file is
  -- left UNCHANGED, the rejection is logged WITH candidate_metrics, and the failed cycle
  -- is still snapshotted (visible).
  test_reject_preserves_prior_rubric_and_logs_rejection = function()
    local base = runtime_dir("learn_bad")
    local rubric_path = base .. "/area_rubric.json"
    local ts = 1730000000002

    -- seed a prior accepted rubric and prove relearn does NOT overwrite it on reject.
    os.execute("mkdir -p '" .. base .. "'")
    local sentinel = '{"_seed":"PRIOR_UNCHANGED","selection_model":{"accepted":true,"auc":0.99}}'
    file.write(rubric_path, sentinel)

    local result = t.run_department("departments/relearn/main.lua", {
      queue = "codex_relearn_tick",
      ts = ts,
      payload = {
        learning_root = base,
        rubric_path = rubric_path,
        corpora = { selection = non_separable_selection(), engagement = {}, pr_style = {} },
        outcomes = {},
        prior_rubric = json.decode(sentinel),
      },
    })
    t.eq(result.exit_code, 0)

    local row = last_jsonl_row(base .. "/relearn_log.jsonl")
    t.eq(row.accepted, false)
    t.eq(row.status, "rejected")
    t.is_true(type(row.candidate_metrics) == "table")
    t.is_true(type(row.candidate_metrics.auc) == "number")
    t.is_true(row.candidate_metrics.auc < 0.70)

    -- prior accepted rubric preserved (NOT overwritten on reject)
    local rubric = json.decode(file.read(rubric_path))
    t.eq(rubric._seed, "PRIOR_UNCHANGED")
    t.eq(rubric.selection_model.accepted, true)

    -- failed cycle still snapshotted; the candidate marks accepted=false
    local snap_path = base .. "/rubric_history/area_rubric." .. ts .. ".json"
    t.eq(file.exists(snap_path), true)
    local snap = json.decode(file.read(snap_path))
    t.eq(snap.selection_model.accepted, false)
  end,
}
