-- codex-saga durable outcomes-channel tests (the bridge codex-learn reads; DRY-RUN,
-- mock gh, no network). Assert: the §5 JSON encoder round-trips through json.decode;
-- path resolution follows the contract; track APPENDS a proposed/pending line and
-- outcome_watch APPENDS a final merged line (latest-wins by dedup_key yields merged);
-- the durable append is NOT suppressed by the GitHub outcome_marker; ZERO foreign
-- writes throughout.
local core = require("core")
local tk = fkst.test

local function json_escape(s)
  return (tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"))
end

local function foreign_writes(calls)
  local n = 0
  for _, call in ipairs(calls or {}) do
    local rendered = tostring(call.rendered or "")
    if rendered:find("issue create", 1, true) ~= nil
      or rendered:find("issue comment", 1, true) ~= nil
      or rendered:find("pr create", 1, true) ~= nil then
      n = n + 1
    end
  end
  return n
end

local function control_body(dedup, original_ref)
  return core.control_marker(dedup) .. "\n"
    .. core.source_marker(dedup, { kind = "external", ref = original_ref })
end

local DEDUP = "codex-triage:candidate:openai/codex#1234"
local ORIGINAL_REF = "openai/codex#issues/1234"

-- A fresh durable path with an existing parent (FKST_RUNTIME_ROOT), unique per test.
local function fresh_path(tag)
  return (os.getenv("FKST_RUNTIME_ROOT") or ".") .. "/outcomes-" .. tag .. ".jsonl"
end

return {
  -- Path resolution: explicit override wins; else FKST_DURABLE_ROOT/codex-saga/...
  test_outcomes_path_resolution = function()
    -- The default path ends with the contract suffix.
    tk.is_true(core.outcomes_path():find("/codex-saga/outcomes.jsonl", 1, true) ~= nil)
  end,

  -- The §5 encoder produces valid JSON that round-trips through json.decode,
  -- including the fold fields area_labels + type.
  test_encode_outcome_json_round_trips = function()
    local line = core.encode_outcome_json({
      source_ref = { kind = "external", ref = ORIGINAL_REF },
      dedup_key = DEDUP,
      picked_score = 0.73,
      area_labels = { "exec", "bug" },
      type = "bug",
      exemplars_used = { "openai/codex#178", "openai/codex#1" },
      engagement_reaction = "invited",
      ci = "pending",
      review_comment_themes = {},
      disposition = "proposed",
      advocate_verdict = "pass",
      advocate_reason = "approved",
      -- deliberation signals (learning-model §7): per-angle map + judgment count.
      consensus_angles = { alignment = "approve", blast_radius = "reject", ["devils-advocate"] = "dissent" },
      deliberation_count = 3,
    })
    local decoded = json.decode(line)
    tk.eq(decoded.dedup_key, DEDUP)
    tk.eq(decoded.disposition, "proposed")
    tk.eq(decoded.ci, "pending")
    tk.eq(decoded.source_ref.ref, ORIGINAL_REF)
    tk.eq(decoded.picked_score, 0.73)
    tk.eq(decoded.area_labels[1], "exec")
    tk.eq(decoded.type, "bug")
    tk.eq(decoded.exemplars_used[1], "openai/codex#178")
    -- the new deliberation fields round-trip through json.decode (additive for codex-learn).
    tk.eq(decoded.consensus_angles.alignment, "approve")
    tk.eq(decoded.consensus_angles.blast_radius, "reject")
    tk.eq(decoded.deliberation_count, 3)
  end,

  -- The additive scoreboard fields (state/reason/root_cause) round-trip; absent -> null.
  test_scoreboard_fields_round_trip = function()
    local line = core.encode_outcome_json({
      dedup_key = DEDUP, state = "needs_info", reason = "not_reproduced",
      root_cause = "codex-rs/protocol/src/permissions.rs:1023",
    })
    local decoded = json.decode(line)
    tk.eq(decoded.state, "needs_info")
    tk.eq(decoded.reason, "not_reproduced")
    tk.eq(decoded.root_cause, "codex-rs/protocol/src/permissions.rs:1023")
    -- absent scoreboard fields encode to JSON null (additive; codex-learn ignores them).
    tk.is_true(core.encode_outcome_json({ dedup_key = "d" }):find('"state":null', 1, true) ~= nil)
  end,

  -- record_terminal_drop appends ONE durable §5 drop record (state + WHY), performs NO
  -- foreign write (dry-run-safe), and uses disposition="dropped" OUTSIDE the resolved set.
  test_record_terminal_drop_appends_inert_drop = function()
    local path = fresh_path("drop")
    core.record_terminal_drop(DEDUP, {
      state = "needs_info", reason = "not_reproduced",
      source_ref = { kind = "external", ref = ORIGINAL_REF },
      picked_score = 0.89, area_labels = { "bug", "regression" }, type = "bug",
    }, { path = path })
    tk.eq(#tk.command_calls(), 0) -- NO foreign write: local + unconditional append
    local rec = core.latest_outcome_by_dedup(core.read_outcomes({ path = path }))[DEDUP]
    tk.eq(rec.state, "needs_info")
    tk.eq(rec.reason, "not_reproduced")
    tk.eq(rec.disposition, "dropped")
    tk.eq(rec.type, "bug")
  end,

  -- The per-angle map encodes with SORTED keys, so the durable line is deterministic;
  -- a nil map encodes to null (absent deliberation), an empty map to {}.
  test_consensus_angles_encode_is_deterministic = function()
    local a = core.encode_outcome_json({ dedup_key = "d", consensus_angles = { blast_radius = "reject", alignment = "approve" } })
    local b = core.encode_outcome_json({ dedup_key = "d", consensus_angles = { alignment = "approve", blast_radius = "reject" } })
    tk.eq(a, b) -- key order does not affect the encoded line
    tk.is_true(a:find('"consensus_angles":{"alignment":"approve","blast_radius":"reject"}', 1, true) ~= nil)
    -- a nil map encodes to JSON null (not {}), so it decodes to a non-table (absent map).
    tk.is_true(core.encode_outcome_json({ dedup_key = "d" }):find('"consensus_angles":null', 1, true) ~= nil)
  end,

  -- The latest-wins-by-dedup_key reader (the SAME view codex-learn takes) returns the
  -- LAST record per dedup_key, so a final record supersedes an earlier pending one.
  test_latest_outcome_by_dedup_takes_last = function()
    local latest = core.latest_outcome_by_dedup({
      { dedup_key = "d", disposition = "proposed", ci = "pending" },
      { dedup_key = "d", disposition = "merged", ci = "pass" },
      { dedup_key = "e", disposition = "closed" },
    })
    tk.eq(latest["d"].disposition, "merged")
    tk.eq(latest["d"].ci, "pass")
    tk.eq(latest["e"].disposition, "closed")
  end,

  -- DEPARTMENT FLOW: track appends a proposed/pending line; outcome_watch (mocked
  -- MERGED PR) appends a final merged/pass line; latest-wins by dedup_key = merged.
  -- The durable append happens even though track already wrote the GitHub mirror
  -- (marker present) - the marker never suppresses the durable append. ZERO foreign
  -- writes throughout.
  test_track_then_outcome_watch_closes_loop = function()
    local path = fresh_path("flow")
    local env = { FKST_LEARNING_OUTCOMES_PATH = path }

    -- 1) track: initial record (carries labels so area_labels + type are recorded).
    local r1 = tk.run_department("departments/track/main.lua", {
      queue = "codex_proposed",
      payload = {
        schema = "codex-saga.proposed.v1",
        dedup_key = DEDUP,
        source_ref = { kind = "external", ref = ORIGINAL_REF },
        control_issue = "7",
        picked_score = 0.73,
        labels = { "bug", "exec" },
        exemplars_used = { "openai/codex#178" },
        advocate_verdict = "pass",
      },
    }, { env = env })
    tk.eq(r1.exit_code, 0)
    local after_track = core.latest_outcome_by_dedup(core.read_outcomes({ path = path }))
    tk.eq(after_track[DEDUP].disposition, "proposed")
    tk.eq(after_track[DEDUP].ci, "pending")
    -- the PROPOSED line carries the §5 fold fields.
    tk.eq(after_track[DEDUP].area_labels[1], "bug")
    tk.eq(after_track[DEDUP].type, "bug")
    tk.eq(foreign_writes(tk.command_calls()), 0)

    -- 2) outcome_watch: re-derive a MERGED PR (CI pass) and append the FINAL record.
    tk.mock_command("gh issue list", {
      stdout = '[{"number":7,"author":{"login":"codex-bot"},"body":"' .. json_escape(control_body(DEDUP, ORIGINAL_REF)) .. '"}]',
    })
    tk.mock_command("gh pr list", {
      stdout = '[{"state":"MERGED","statusCheckRollup":[{"conclusion":"SUCCESS"}],"reviews":[{"state":"APPROVED","body":"add tests"}],"comments":[]}]',
    })
    local r2 = tk.run_department("departments/outcome_watch/main.lua", {
      queue = "codex_outcome_watch_tick",
      payload = {},
    }, { env = { FKST_LEARNING_OUTCOMES_PATH = path, FKST_GITHUB_BOT_LOGIN = "codex-bot" } })
    tk.eq(r2.exit_code, 0)

    -- 3) the durable JSONL now has TWO lines for DEDUP; latest-wins = merged/pass.
    local records = core.read_outcomes({ path = path })
    local seen = 0
    for _, rec in ipairs(records) do
      if rec.dedup_key == DEDUP then seen = seen + 1 end
    end
    tk.is_true(seen >= 2) -- proposed line + final merged line both appended
    local latest = core.latest_outcome_by_dedup(records)
    tk.eq(latest[DEDUP].disposition, "merged")
    tk.eq(latest[DEDUP].ci, "pass")
    -- the FINAL line inherits the §5 fold fields from track's proposed record, so BOTH
    -- lines carry area_labels + type (codex-learn can fold the final record alone).
    tk.eq(latest[DEDUP].area_labels[1], "bug")
    tk.eq(latest[DEDUP].type, "bug")
    -- the closed loop never performed a foreign write (gh reads only + local append).
    tk.eq(foreign_writes(tk.command_calls()), 0)
  end,
}
