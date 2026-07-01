-- codex-learn/raisers/relearn: the scheduled re-derivation tick.
--
-- STATIC source declaration ONLY (PRC §3): raisers carry NO logic. The interval is
-- read once at graph-load from FKST_RELEARN_INTERVAL (host fact, .fkst/env) and falls
-- back to a weekly default; this is a single env read, not polling. The relearn
-- department consumes `codex_relearn_tick` and does ALL the work (fold outcomes,
-- re-fit weights, re-induce styleguides, re-rank exemplars, calibrate the advocate,
-- snapshot + log). One tick => one re-derivation.
--
-- Mirrors codex-saga/raisers/invite_watch.lua's shape.
local interval = "168h" -- weekly default re-derivation cadence.
if type(os) == "table" and type(os.getenv) == "function" then
  local configured = os.getenv("FKST_RELEARN_INTERVAL")
  if type(configured) == "string" and configured ~= "" then
    interval = configured
  end
end

return {
  type = "cron",
  interval = interval,
  produces = "codex_relearn_tick",
}
