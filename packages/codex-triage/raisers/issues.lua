-- codex-triage/raisers/issues: cron tick that paces issue discovery.
--
-- Raisers carry NO polling logic (PRC §3) - they only declare a static source.
-- The score_dedup department consumes this tick, reads the durable issue MIRROR
-- (produced out-of-band by scripts/reconcile_issues.py; NEVER a live in-tick poll),
-- scores + dedups + applies the top-N cap, and raises codex_candidate. It fails closed
-- when the mirror is absent/stale. This 5m tick is independent of the mirror's own
-- full-refresh cadence (N-day, run by the reconcile producer).
return {
  type = "cron",
  interval = "5m",
  produces = "codex_issue_poll_tick",
}
