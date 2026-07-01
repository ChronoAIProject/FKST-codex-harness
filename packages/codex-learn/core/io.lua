-- core.io: the SIDE-EFFECTING boundary of relearn -- learning-root resolution, the
-- corpus/outcomes/prior-rubric reads, and the commit of the distilled banks.
--
-- All writes are PARAMETERIZED by a learning-root so tests target a temp dir and
-- NEVER touch the real committed data/. relearn is the ONLY writer of these banks.
-- Directory creation uses Lua stdlib (os.execute mkdir -p): file.write cannot create
-- parents, and the engine's exec_sync is hijacked/fail-closed under `test`, whereas
-- stdlib os.* runs in every context (stdlib-first, per the substrate boundary doc).
local S = {}

-- ts source discipline: prefer the engine-stamped event ts (unix ms), else the host
-- clock via the SDK `now()` (unix seconds -> ms). NEVER os.time/os.date for the
-- artifact timestamp (non-deterministic across hosts / not engine-provided).
local function event_ts(event)
  if type(event) == "table" then
    local ts = tonumber(event.ts)
    if ts and ts > 0 then
      return math.floor(ts)
    end
  end
  if type(now) == "function" then
    local secs = tonumber(now())
    if secs and secs > 0 then
      return math.floor(secs) * 1000
    end
  end
  return nil -- caller must flag: no engine time available.
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function parent_dir(path)
  return tostring(path):match("^(.*)/[^/]+$")
end

function S.install(M)
  M.event_ts = event_ts

  -- relearn_config(overrides) -> all input + output paths. Every path is overridable
  -- (host env for production, the `overrides` table for tests).
  function M.relearn_config(overrides)
    overrides = overrides or {}
    local function pick(key, env, default)
      return overrides[key] or M.read_env(env) or default
    end
    local learning_root = pick("learning_root", "FKST_LEARNING_ROOT", "data/learning")
    -- Durable-outcomes channel contract (shared with codex-saga's writer): the reader
    -- resolves the SAME path the writer roots at -- FKST_LEARNING_OUTCOMES_PATH if set,
    -- else <FKST_DURABLE_ROOT or ".fkst/durable">/codex-saga/outcomes.jsonl. codex-saga
    -- APPENDS one §5 record per line (track's proposed/pending, then outcome_watch's
    -- final merged|closed); the reader dedups latest-wins (see relearn.resolve_outcomes).
    local durable_root = M.read_env("FKST_DURABLE_ROOT") or ".fkst/durable"
    local cfg = {
      learning_root = learning_root,
      rubric_path = pick("rubric_path", "FKST_LEARNING_RUBRIC_PATH", "data/area_rubric.json"),
      corpus_selection_path = pick("corpus_selection_path", "FKST_LEARNING_CORPUS_SELECTION", "data/corpus_selection.jsonl"),
      corpus_engagement_path = pick("corpus_engagement_path", "FKST_LEARNING_CORPUS_ENGAGEMENT", "data/corpus_engagement.jsonl"),
      corpus_pr_style_path = pick("corpus_pr_style_path", "FKST_LEARNING_CORPUS_PR_STYLE", "data/corpus_pr_style.jsonl"),
      outcomes_path = pick("outcomes_path", "FKST_LEARNING_OUTCOMES_PATH", durable_root .. "/codex-saga/outcomes.jsonl"),
    }
    cfg.rubric_history_dir = learning_root .. "/rubric_history"
    cfg.relearn_log_path = learning_root .. "/relearn_log.jsonl"
    cfg.engagement_styleguide_path = learning_root .. "/engagement_styleguide.md"
    cfg.pr_styleguide_path = learning_root .. "/pr_styleguide.md"
    return cfg
  end

  -- ensure_dir(dir) -> best-effort recursive mkdir. Idempotent (mkdir -p).
  function M.ensure_dir(dir)
    if dir == nil or dir == "" then
      return false
    end
    if file.exists(dir) then
      return true
    end
    if type(os) == "table" and type(os.execute) == "function" then
      os.execute("mkdir -p " .. shell_quote(dir))
      return file.exists(dir)
    end
    return false
  end

  local function read_text(path)
    if not file.exists(path) then
      return nil
    end
    local ok, text = pcall(file.read, path)
    if not ok or type(text) ~= "string" then
      return nil
    end
    return text
  end

  -- read_corpus(path) -> array of decoded JSONL records (empty if absent).
  function M.read_corpus(path)
    return M.decode_jsonl(read_text(path) or "")
  end

  -- read_rubric(path) -> the decoded prior rubric table, or nil.
  function M.read_rubric(path)
    local text = read_text(path)
    if text == nil or text == "" then
      return nil
    end
    local ok, parsed = pcall(json.decode, text)
    if ok and type(parsed) == "table" then
      return parsed
    end
    return nil
  end

  -- read_inputs(config[, overrides]) -> the run_cycle input bundle. Test overrides
  -- short-circuit each file read so the suite needs no disk/network.
  function M.read_inputs(config, overrides)
    overrides = overrides or {}
    local corpora = overrides.corpora
    if corpora == nil then
      corpora = {
        selection = M.read_corpus(config.corpus_selection_path),
        engagement = M.read_corpus(config.corpus_engagement_path),
        pr_style = M.read_corpus(config.corpus_pr_style_path),
      }
    end
    local outcomes = overrides.outcomes
    if outcomes == nil then
      outcomes = M.read_corpus(config.outcomes_path)
    end
    local prior_rubric = overrides.prior_rubric
    if prior_rubric == nil then
      prior_rubric = M.read_rubric(config.rubric_path)
    end
    local prior_strictness = overrides.prior_strictness
    if prior_strictness == nil and type(prior_rubric) == "table"
      and type(prior_rubric.advocate_calibration) == "table" then
      prior_strictness = prior_rubric.advocate_calibration.strictness
    end
    return {
      corpora = corpora,
      outcomes = outcomes,
      prior_rubric = prior_rubric,
      prior_strictness = prior_strictness,
    }
  end

  -- append_jsonl(path, line): read-existing + append one line (file.write overwrites).
  function M.append_jsonl(path, line)
    local existing = read_text(path) or ""
    if existing ~= "" and existing:sub(-1) ~= "\n" then
      existing = existing .. "\n"
    end
    file.write(path, existing .. line .. "\n")
  end

  -- commit(result, config) -> the written-path manifest. ALWAYS writes the snapshot,
  -- the relearn_log row, and both styleguides (a rejected cycle stays VISIBLE). Only
  -- on accept is the published data/area_rubric.json overwritten; on reject the prior
  -- accepted rubric is left UNCHANGED.
  function M.commit(result, config)
    M.ensure_dir(config.learning_root)
    M.ensure_dir(config.rubric_history_dir)

    local snapshot_path = config.rubric_history_dir .. "/area_rubric." .. tostring(result.ts) .. ".json"
    file.write(snapshot_path, M.json_encode(result.candidate_rubric))
    M.append_jsonl(config.relearn_log_path, M.json_encode(result.log_row))
    file.write(config.engagement_styleguide_path, result.styleguides.engagement_md)
    file.write(config.pr_styleguide_path, result.styleguides.pr_md)

    local rubric_written = false
    if result.accepted then
      local parent = parent_dir(config.rubric_path)
      if parent then
        M.ensure_dir(parent)
      end
      file.write(config.rubric_path, M.json_encode(result.candidate_rubric))
      rubric_written = true
    end

    return {
      snapshot_path = snapshot_path,
      relearn_log_path = config.relearn_log_path,
      engagement_styleguide_path = config.engagement_styleguide_path,
      pr_styleguide_path = config.pr_styleguide_path,
      rubric_path = rubric_written and config.rubric_path or nil,
      rubric_written = rubric_written,
    }
  end
end

return S
