-- codex-learn fold-feature tests (#14: fold real anatomy/demand into the re-fit).
-- relearn.fold_outcomes now carries anatomy_flags + reactions from the §5 outcome record
-- into the folded selection record, and fit.feature_vector consumes them with a SAFE
-- FALLBACK: present -> the anatomy/demand features train for real; absent -> they train as
-- 0 (unchanged from today). Pure, inline fixtures: no IO/network.
local core = require("core")
local t = fkst.test

local function merged_outcome(extra)
  local oc = {
    source_ref = { ref = "openai/codex#900" },
    dedup_key = "codex-triage:dup:openai/codex#900",
    picked_score = 70,
    area_labels = { "bug", "exec" },
    type = "bug",
    disposition = "merged", -- resolved => folds into the selection corpus
  }
  for k, v in pairs(extra or {}) do
    oc[k] = v
  end
  return oc
end

return {
  -- WITH features: a folded outcome carrying anatomy_flags + reactions trains non-zero
  -- anatomy AND demand features (previously always 0 for real outcomes).
  test_fold_carries_anatomy_and_reactions_into_features = function()
    local augmented, counts = core.fold_outcomes({ selection = {} }, {
      merged_outcome({
        anatomy_flags = { version = true, repro = true, error = true },
        reactions = 20,
      }),
    })
    t.eq(counts.selection, 1)
    local folded = augmented.selection[#augmented.selection]
    t.is_true(type(folded.anatomy_flags) == "table")
    t.eq(folded.reactions, 20)

    local fv = core.feature_vector(folded)
    t.is_true(fv.anatomy > 0) -- version+repro+error rendered into the synthesized body
    t.is_true(fv.demand > 0) -- 20 reactions -> non-zero demand
  end,

  -- WITHOUT features (safe fallback): an outcome with no anatomy_flags/reactions still folds
  -- and trains anatomy/demand as 0 -- exactly today's behavior, never an error.
  test_fold_without_features_falls_back_to_zero = function()
    local augmented = core.fold_outcomes({ selection = {} }, { merged_outcome() })
    local folded = augmented.selection[#augmented.selection]
    t.is_nil(folded.anatomy_flags)
    t.is_nil(folded.reactions)

    local fv = core.feature_vector(folded)
    t.eq(fv.anatomy, 0)
    t.eq(fv.demand, 0)
  end,
}
