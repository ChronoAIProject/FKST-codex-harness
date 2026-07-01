-- core.outcomes_store: the DURABLE outcomes JSONL channel (learning-model §5/§6).
--
-- This is the bridge codex-learn/relearn READS. codex-saga records raw per-attempt §5
-- outcome records here, ONE JSON object per line, APPEND-ONLY (latest-wins by
-- dedup_key, so the re-derived final record supersedes the initial pending one). It is
-- GITIGNORED durable runtime under FKST_DURABLE_ROOT - the correct state split for raw
-- per-attempt outcomes.
--
-- The append is UNCONDITIONAL: the GitHub outcome_marker gates only the VISIBLE
-- control-issue comment (core.track / core.egress), NEVER this durable append. So
-- track's initial proposed/pending line and outcome_watch's final merged/closed line
-- both land regardless of the marker.
--
-- The SDK is decode-only (no json.encode - JSON is the engine wire boundary), so this
-- module owns a small encoder for the FIXED §5 record shape; codex-learn re-reads it
-- with json.decode.
local S = {}

function S.install(M)
  -- The durable outcomes path. codex-learn is aligned to this IDENTICAL resolution:
  --   FKST_LEARNING_OUTCOMES_PATH, else
  --   (FKST_DURABLE_ROOT or ".fkst/durable") .. "/codex-saga/outcomes.jsonl".
  function M.outcomes_path()
    local override = M.read_env("FKST_LEARNING_OUTCOMES_PATH")
    if M.is_nonempty_string(override) then
      return override
    end
    local root = M.read_env("FKST_DURABLE_ROOT") or ".fkst/durable"
    return root .. "/codex-saga/outcomes.jsonl"
  end

  -- ---- minimal JSON encoder for the fixed §5 record shape ----------------------
  local function escape_json_string(value)
    local s = tostring(value):gsub('[%c\\"]', function(c)
      if c == "\\" then return "\\\\" end
      if c == '"' then return '\\"' end
      if c == "\n" then return "\\n" end
      if c == "\r" then return "\\r" end
      if c == "\t" then return "\\t" end
      return string.format("\\u%04x", string.byte(c))
    end)
    return '"' .. s .. '"'
  end

  local function encode_string_array(arr)
    local parts = {}
    for _, value in ipairs(arr or {}) do
      table.insert(parts, escape_json_string(value))
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end

  -- Encode a small string->string map (the per-angle deliberation verdicts) with keys
  -- SORTED so the JSONL line is deterministic (stable tests + stable dedup). nil -> null,
  -- empty table -> {}. Values are coerced to strings (the angle verdicts are scalars).
  local function encode_string_map(map)
    if type(map) ~= "table" then
      return "null"
    end
    local keys = {}
    for key in pairs(map) do
      keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
      table.insert(parts, escape_json_string(key) .. ":" .. escape_json_string(map[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end

  local function encode_source_ref(source_ref)
    if type(source_ref) ~= "table" then
      return "null"
    end
    local parts = {}
    if source_ref.kind ~= nil then
      table.insert(parts, '"kind":' .. escape_json_string(source_ref.kind))
    end
    if source_ref.ref ~= nil then
      table.insert(parts, '"ref":' .. escape_json_string(source_ref.ref))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end

  local function encode_number_or_null(n)
    if type(n) ~= "number" or n ~= n or n == math.huge or n == -math.huge then
      return "null"
    end
    return string.format("%.10g", n)
  end

  local function encode_string_or_null(s)
    if s == nil then
      return "null"
    end
    return escape_json_string(s)
  end

  -- Encode ONE §5 record (field order per the durable-outcomes contract).
  function M.encode_outcome_json(record)
    record = record or {}
    local fields = {
      '"source_ref":' .. encode_source_ref(record.source_ref),
      '"dedup_key":' .. encode_string_or_null(record.dedup_key),
      '"picked_score":' .. encode_number_or_null(record.picked_score),
      '"area_labels":' .. encode_string_array(record.area_labels),
      '"type":' .. encode_string_or_null(record.type),
      '"exemplars_used":' .. encode_string_array(record.exemplars_used),
      '"engagement_reaction":' .. encode_string_or_null(record.engagement_reaction),
      '"ci":' .. encode_string_or_null(record.ci),
      '"review_comment_themes":' .. encode_string_array(record.review_comment_themes),
      '"disposition":' .. encode_string_or_null(record.disposition),
      '"advocate_verdict":' .. encode_string_or_null(record.advocate_verdict),
      '"advocate_reason":' .. encode_string_or_null(record.advocate_reason),
      -- Deliberation signals (learning-model §7): the per-angle consensus + dissent
      -- verdicts and the count of independent judgments the gate weighed. APPENDED at
      -- the end so the addition is additive for codex-learn's json.decode reader.
      '"consensus_angles":' .. encode_string_map(record.consensus_angles),
      '"deliberation_count":' .. encode_number_or_null(record.deliberation_count),
      -- Saga scoreboard signals (dashboard statline contract, DATA-RETRIEVAL.md): the
      -- saga `state` this record represents, the controlled `reason` WHY, and the
      -- diagnose `root_cause`. Additive + optional (null when absent) so codex-learn's
      -- json.decode ignores them; the local dashboard reader maps them 1:1 to the statline.
      '"state":' .. encode_string_or_null(record.state),
      '"reason":' .. encode_string_or_null(record.reason),
      '"root_cause":' .. encode_string_or_null(record.root_cause),
      -- Free-text annotation/finding (e.g. "already fixed upstream by #18499"), for the
      -- human/agent review trail. Additive + optional; codex-learn's json.decode ignores it.
      '"note":' .. encode_string_or_null(record.note),
    }
    return "{" .. table.concat(fields, ",") .. "}"
  end

  -- Best-effort parent-dir creation for the PRODUCTION default path (the codex-saga
  -- subdir under FKST_DURABLE_ROOT). In test mode external commands fail closed, so
  -- tests use FKST_LEARNING_OUTCOMES_PATH with an existing parent and never reach this.
  function M.ensure_parent_dir(path)
    local dir = tostring(path):match("^(.*)/[^/]+$")
    if M.is_nonempty_string(dir) then
      pcall(M.run_argv, { argv = { "mkdir", "-p", dir }, timeout = 30 })
    end
  end

  -- APPEND one §5 record to the durable outcomes JSONL. UNCONDITIONAL - never gated by
  -- the GitHub outcome_marker. Serialized across pipeline processes by with_lock so
  -- concurrent appends don't clobber (read-modify-write; file.write has no append mode).
  function M.append_outcome(dedup_key, outcome, opts)
    outcome = outcome or {}
    opts = opts or {}
    local record = {
      source_ref = outcome.source_ref,
      dedup_key = dedup_key,
      picked_score = outcome.picked_score,
      area_labels = outcome.area_labels,
      type = outcome.type,
      exemplars_used = outcome.exemplars_used,
      engagement_reaction = outcome.engagement_reaction,
      ci = outcome.ci,
      review_comment_themes = outcome.review_comment_themes,
      disposition = outcome.disposition,
      advocate_verdict = outcome.advocate_verdict,
      advocate_reason = outcome.advocate_reason,
      consensus_angles = outcome.consensus_angles,
      deliberation_count = outcome.deliberation_count,
      state = outcome.state,
      reason = outcome.reason,
      root_cause = outcome.root_cause,
      note = outcome.note,
    }
    local line = M.encode_outcome_json(record)
    local path = opts.path or M.outcomes_path()
    with_lock("codex-saga/outcomes-append", function()
      local existing = ""
      if file.exists(path) then
        local ok, contents = pcall(file.read, path)
        if ok and type(contents) == "string" then
          existing = contents
        end
      end
      local content = existing .. line .. "\n"
      local ok = pcall(file.write, path, content)
      if not ok then
        M.ensure_parent_dir(path)
        file.write(path, content) -- fail-loud if the durable channel is unwritable
      end
    end)
    return path
  end

  -- record_terminal_drop(dedup_key, drop[, opts]) -> append ONE durable §5 record for a
  -- PRE-track terminal drop (e.g. diagnose needs_info), so the dashboard scoreboard/funnel
  -- reflects a candidate the loop attempted but did not carry forward. Like
  -- record_deliberation this is UNCONDITIONAL + local (dry-run-safe, NO foreign write) and
  -- uses disposition="dropped" (OUTSIDE codex-learn's resolved set {merged,closed,ignored}),
  -- so the drop is retrievable yet inert to the learning fold. drop:
  --   { state, reason, source_ref, picked_score, area_labels, type, root_cause }
  -- BEST-EFFORT: a stats side-channel must NEVER turn a safety drop into a pipeline failure,
  -- so a durable-channel hiccup is swallowed (returns nil) - mirrors record_deliberation.
  function M.record_terminal_drop(dedup_key, drop, opts)
    drop = drop or {}
    local outcome = {
      source_ref = drop.source_ref,
      picked_score = drop.picked_score,
      area_labels = drop.area_labels,
      type = drop.type,
      engagement_reaction = "none",
      disposition = "dropped",
      state = drop.state,
      reason = drop.reason,
      root_cause = drop.root_cause,
    }
    local ok, path = pcall(M.append_outcome, dedup_key, outcome, opts)
    if ok then
      return path
    end
    return nil
  end

  -- ---- reader: the SAME latest-wins-by-dedup_key view codex-learn takes --------
  function M.read_outcomes(opts)
    opts = opts or {}
    local path = opts.path or M.outcomes_path()
    if not file.exists(path) then
      return {}
    end
    local ok, text = pcall(file.read, path)
    if not ok then
      return {}
    end
    local records = {}
    for line in tostring(text):gmatch("[^\n]+") do
      local trimmed = M.trim(line)
      if M.is_nonempty_string(trimmed) then
        local ok2, record = pcall(json.decode, trimmed)
        if ok2 and type(record) == "table" then
          table.insert(records, record)
        end
      end
    end
    return records
  end

  -- Dedup by dedup_key taking the LAST occurrence (final supersedes pending).
  function M.latest_outcome_by_dedup(records)
    local latest = {}
    for _, record in ipairs(records or {}) do
      if type(record) == "table" and M.is_nonempty_string(record.dedup_key) then
        latest[record.dedup_key] = record
      end
    end
    return latest
  end
end

return S
