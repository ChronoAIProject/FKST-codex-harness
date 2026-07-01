-- codex-saga deliberation-capture tests (DRY-RUN, no network). Assert: the per-angle
-- verdicts zip into a named map; a gate REFUSAL is appended to the durable outcomes
-- channel with ZERO foreign write; its disposition is OUTSIDE codex-learn's resolved
-- set (retrievable yet inert to the learning fold); and the funnel stats derive from
-- the latest-wins view.
local core = require("core")
local tk = fkst.test

-- codex-learn's resolved set (relearn.is_resolved_outcome). A deliberation/refusal
-- disposition MUST NOT be one of these, or a refusal would be miscounted as a win/loss.
local RESOLVED = { merged = true, closed = true, ignored = true }

local function fresh_path(tag)
  return (os.getenv("FKST_RUNTIME_ROOT") or ".") .. "/deliberation-" .. tag .. ".jsonl"
end

return {
  -- zip_angles keys the positional consensus verdicts by angle name and folds in the
  -- devil's-advocate dissent (blocking -> "block", else "dissent").
  test_zip_angles_keys_by_angle_name = function()
    local map = core.zip_angles({ "approve", "reject" }, { blocking = false })
    tk.eq(map.alignment, "approve")
    tk.eq(map.blast_radius, "reject")
    tk.eq(map["devils-advocate"], "dissent")
    local blocked = core.zip_angles({ "approve", "approve" }, { blocking = true })
    tk.eq(blocked["devils-advocate"], "block")
  end,

  -- deliberation_count = consensus angles judged + the dissent angle.
  test_deliberation_count_tallies_judgments = function()
    tk.eq(core.deliberation_count({ "approve", "reject" }, { blocking = false }), 3)
    tk.eq(core.deliberation_count({ "approve", "reject" }, nil), 2)
    tk.eq(core.deliberation_count(nil, nil), 0)
  end,

  -- record_deliberation appends ONE durable refusal record with the per-angle verdicts,
  -- performs NO foreign write (dry-run-safe), and uses a disposition OUTSIDE the resolved
  -- set so codex-learn's fold + calibration skip it.
  test_record_deliberation_appends_inert_refusal = function()
    local path = fresh_path("refuse")
    core.record_deliberation("codex-triage:candidate:openai/codex#42", {
      reason = "consensus",
      source_ref = { kind = "external", ref = "openai/codex#issues/42" },
      picked_score = 0.61,
      area_labels = { "bug" },
      advocate_verdict = "refuted",
      advocate_reason = "blast_radius rejected: repro not proven",
      consensus_angles = core.zip_angles({ "approve", "reject" }, { blocking = false }),
      deliberation_count = 3,
    }, { path = path })

    tk.eq(#tk.command_calls(), 0) -- NO foreign write: the append is local + unconditional
    local latest = core.latest_outcome_by_dedup(core.read_outcomes({ path = path }))
    local rec = latest["codex-triage:candidate:openai/codex#42"]
    tk.eq(rec.disposition, "refused_consensus")
    tk.eq(rec.advocate_verdict, "refuted")
    tk.eq(rec.consensus_angles.blast_radius, "reject")
    tk.eq(rec.deliberation_count, 3)
    tk.is_true(RESOLVED[rec.disposition] ~= true) -- inert to codex-learn (never a win/loss)
  end,

  -- The gate drop reasons all map to a refused_* disposition, none in the resolved set.
  test_refusal_dispositions_are_all_inert = function()
    for _, disposition in pairs(core.refusal_dispositions) do
      tk.is_true(RESOLVED[disposition] ~= true)
      tk.is_true(tostring(disposition):find("^refused") ~= nil)
    end
  end,

  -- deliberation_stats derives the funnel (deliberated/refused/cleared) from the durable
  -- channel, latest-wins by dedup_key. A consensus refusal is the advocate hero stat.
  test_deliberation_stats_derives_funnel = function()
    local path = fresh_path("funnel")
    core.record_deliberation("d1", { reason = "consensus" }, { path = path })
    core.record_deliberation("d2", { reason = "volume_cap" }, { path = path })
    -- a PASS lands as a normal proposed record (non-refused disposition).
    core.append_outcome("d3", { disposition = "proposed", deliberation_count = 3 }, { path = path })

    local s = core.deliberation_stats({ path = path })
    tk.eq(s.refused, 2)
    tk.eq(s.refused_by_advocate, 1) -- only the consensus drop is an advocate refusal
    tk.eq(s.cleared, 1)
    tk.eq(s.deliberated, 2) -- reached the panel: refused_consensus + the cleared pass
  end,
}
