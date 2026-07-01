-- codex-saga/raisers/outcome_watch: cron tick that drives the closing-PR outcome
-- re-derivation (learning-model §5/§6 - the closed feedback loop). The outcome_watch
-- department consumes this tick and RE-DERIVES read-only from GitHub the real CI
-- status, review themes, and final disposition of the PRs we proposed, then updates
-- the durable outcome record. No polling logic lives in the raiser itself (PRC §3).
return {
  type = "cron",
  interval = "30m",
  produces = "codex_outcome_watch_tick",
}
