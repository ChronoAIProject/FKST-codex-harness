-- codex-triage/raisers/issues: cron tick that drives the openai/codex issue poll.
--
-- Raisers carry NO polling logic (PRC §3) - they only declare a static source.
-- The score_dedup department consumes this tick, polls openai/codex, applies the
-- rubric + clusters, and raises codex_candidate.
--
-- TODO(Task D/E): tune interval to the configured poll cadence / rate budget.
return {
  type = "cron",
  interval = "5m",
  produces = "codex_issue_poll_tick",
}
