-- codex-learn shared logic (require-able as `core`).
--
-- codex-learn is the scheduled re-derivation engine (docs/learning-model.md §3/§6):
-- it is the ONLY writer of the distilled banks (data/area_rubric.json, the styleguides,
-- and the data/learning/ history + relearn_log). The relearn department consumes one
-- `codex_relearn_tick` and runs one full re-derivation cycle.
--
-- Responsibility split (1000-line cap; one topic per file):
--   core/encode.lua     pure JSON encoder + JSONL helpers (SDK json is decode-only)
--   core/fit.lua        re-fit selection weights + the §6 AUC>=0.70 + monotonic gate
--   core/styleguide.lua induce engagement/PR styleguides + precedent exemplar re-rank
--   core/calibrate.lua  advocate calibration via advocate.gate semantics
--   core/relearn.lua    the PURE re-derivation orchestration (fold/fit/induce/log)
--   core/io.lua         the side-effecting boundary: config, reads, snapshot+log commit
--
-- Payload discipline (spec §6): the tick payload carries only small control fields; the
-- corpora are read by path (data pointers), never inlined into a reliable event.
local M = {}

local function getenv_raw(name)
  if type(os) == "table" and type(os.getenv) == "function" then
    return os.getenv(name)
  end
  return nil
end

local function trim(value)
  if value == nil then
    return nil
  end
  return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- read_env(name): a host fact (config from .fkst/env). nil for unset/empty so callers
-- fall back to the documented defaults.
function M.read_env(name)
  local raw = getenv_raw(name)
  if raw == nil then
    return nil
  end
  local s = trim(raw)
  if s == "" then
    return nil
  end
  return s
end

-- safe_key_segment(value): sanitize an arbitrary string into a single runtime-key
-- path segment ([A-Za-z0-9._-]); used for the per-tick idempotency cache key.
function M.safe_key_segment(value)
  local safe = tostring(value or ""):gsub("[^%w._-]", "_")
  safe = safe:gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if safe == "" or safe:match("^%.+$") then
    return "x" .. safe
  end
  if #safe > 255 then
    safe = safe:sub(1, 255)
  end
  return safe
end

-- Re-raise pipeline failures with the department name attached (fail-loud, narrow
-- error_class) -- the workflow.saga `wrap` hook.
function M.wrap_pipeline_failure(name, fn)
  return function(event)
    local ok, result = pcall(fn, event)
    if not ok then
      error(string.format("codex-learn/%s pipeline failure: %s", name, tostring(result)))
    end
    return result
  end
end

require("core.encode").install(M)
require("core.fit").install(M)
require("core.styleguide").install(M)
require("core.calibrate").install(M)
require("core.relearn").install(M)
require("core.io").install(M)

return M
