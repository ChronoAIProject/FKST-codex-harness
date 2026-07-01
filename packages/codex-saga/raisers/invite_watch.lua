-- codex-saga/raisers/invite_watch: cron tick that drives the maintainer-invite poll.
-- The invite_watch department consumes this tick and re-derives invite state from
-- the control issue (no polling logic in the raiser itself, PRC §3). The invitation
-- precondition this feeds gates any upstream PR (spec §10), re-derived in open_pr.
return {
  type = "cron",
  interval = "15m",
  produces = "codex_invite_watch_tick",
}
