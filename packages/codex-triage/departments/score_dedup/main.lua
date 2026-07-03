-- codex-triage/score_dedup: consume the poll tick, read openai/codex open issues,
-- score (METHODOLOGY §5) every issue then dedup (§7) the ATTEMPT set by cluster,
-- raising codex_candidate with a SMALL payload once per cluster-key.
--
-- G-SAGA-HEAD: the static spec table sits at file head (after requires, before any
-- local function) so the engine graph contract stays greppable.
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "codex_issue_poll_tick" },
  produces = { "codex_candidate" },
  stall_window = "30s",
}

-- done(event) is cheap + side-effect-free. Triage is a stateless adapter (each
-- tick re-derives from the live source), so there is no terminal fact to probe.
local function done(_event)
  return false
end

-- act consumes the cron tick and runs the METHODOLOGY §8 funnel IN ORDER:
-- score+bin EVERY polled issue -> take the ATTEMPT set -> THEN dedup by cluster,
-- raising the FROZEN codex_candidate contract exactly once per cluster-key. A
-- cluster with an ATTEMPT member is never dropped just because its most-reacted
-- representative scored below ATTEMPT (core.attempt_candidates owns that order).
--
-- Injectable seam: in production the issue list + cluster corpus + target are read
-- read-only from openai/codex (gh) and data/ (file). Tests inject them through the
-- event payload (issues / clusters / target) so the suite needs NO network or IO.
-- The production poll path is therefore never hit under `run.sh test`.
local function act(event)
  local payload = (event and event.payload) or {}

  local repo = payload.target or core.contrib_target()

  -- Discovery source precedence (stateless adapter over {injected, cached mirror}):
  --   1) payload.issues  - tests / explicit injection
  --   2) the durable MIRROR - produced out-of-band by scripts/reconcile_issues.py,
  --      or by the in-package SLOW bootstrap (core.bootstrap_advance) below
  --   3) BOOTSTRAP + FAIL-CLOSED - raise nothing this tick, but advance the paced
  --      page-by-page pull a few bounded pages so a missing/stale mirror self-heals
  --      over successive ticks (FKST_TRIAGE_BOOTSTRAP=0 disables, restoring the
  --      pure fail-closed posture). There is STILL no in-tick full-poll path: the
  --      126s all-or-nothing poll must never run inside this 30s-stall department.
  local issues = payload.issues
  local source = "payload"
  if issues == nil then
    issues = core.load_cached_open_issues()
    source = "mirror"
    -- FAIL CLOSED on a missing OR unusable mirror: require a valid, NON-PARTIAL
    -- state stamp, a readable clock, and an age within budget. A missing/partial/
    -- stale/unverifiable state means the map is absent or broken - never score it.
    local unusable = nil
    if issues == nil then
      unusable = "no issue mirror at " .. core.mirror_path()
    else
      local st = core.mirror_state()
      local now = core.now_epoch()
      local fresh = st and tonumber(st.fresh_as_of_epoch)
      local max_age = tonumber(core.read_env("FKST_TRIAGE_MIRROR_MAX_AGE")) or 172800 -- 2 days
      if st == nil or st.partial == true or fresh == nil or now == nil or (now - fresh) > max_age then
        unusable = "issue mirror unusable (missing/partial/stale/unverifiable state)"
      end
    end
    if unusable ~= nil then
      if core.bootstrap_enabled() then
        local step = core.bootstrap_advance()
        log.warn("codex-triage/score_dedup: " .. unusable
          .. " - bootstrap " .. tostring(step.status)
          .. " (pages+" .. tostring(step.pages or 0)
          .. ", next=" .. tostring(step.next_page or "-")
          .. (step.count ~= nil and (", count=" .. tostring(step.count)) or "")
          .. (step.error ~= nil and (", err=" .. tostring(step.error)) or "")
          .. "). Raising NO candidates this tick.")
      else
        log.warn("codex-triage/score_dedup: " .. unusable
          .. " - bootstrap disabled; run scripts/reconcile_issues.py."
          .. " Raising NO candidates this tick.")
      end
      return nil
    end
  end

  local clusters = payload.clusters
  if clusters == nil then
    clusters = core.load_clusters()
  end
  local index = core.cluster_index(clusters)

  -- Dedup'd attempt set, HIGHEST score first, then a top-N cap to bound the downstream
  -- diagnose/codex fan-out (the funnel picks up the rest on later ticks). Cap: positive N
  -- keeps the top N; 0/negative disables the cap. Default 5.
  local candidates = core.attempt_candidates(issues, index, repo)
  -- Deterministic top-N ordering: score desc, then dedup_key, then source_ref.ref, so the
  -- cap keeps a STABLE top-N even when scores tie (Lua table.sort is not stable).
  table.sort(candidates, function(a, b)
    local sa, sb = tonumber(a.score) or 0, tonumber(b.score) or 0
    if sa ~= sb then return sa > sb end
    local ka, kb = tostring(a.dedup_key or ""), tostring(b.dedup_key or "")
    if ka ~= kb then return ka < kb end
    return tostring((a.source_ref or {}).ref or "") < tostring((b.source_ref or {}).ref or "")
  end)

  local latest = {}
  if core.triage_single_flight_enabled() then
    latest = core.latest_saga_outcomes(core.read_saga_outcomes())
    local active_key, active = core.active_saga_candidate(latest)
    if active_key ~= nil then
      log.info("codex-triage/score_dedup: single-flight active=" .. tostring(active_key)
        .. " disposition=" .. tostring(active.disposition) .. " state=" .. tostring(active.state)
        .. " - raising NO candidates this tick.")
      return nil
    end
  end

  -- REMOTE claim ledger (cross-substrate): the tracker's open control issues are the
  -- SHARED source of truth on which candidates are claimed - local outcomes.jsonl only
  -- knows this machine. Live posture only (no command in hermetic dry-run tests), and
  -- FAIL-CLOSED: an unreadable ledger raises nothing this tick (never work blind while
  -- another substrate may hold the claim; the next tick retries).
  local remote = {}
  if core.remote_claims_enabled() then
    remote = core.read_remote_claims()
    if remote == nil then
      log.warn("codex-triage/score_dedup: remote claim ledger (tracker "
        .. core.tracker_repo() .. ") unreadable - raising NO candidates this tick.")
      return nil
    end
    if core.triage_single_flight_enabled() then
      local claim_key, claim_stage = core.active_remote_claim(remote)
      if claim_key ~= nil then
        log.info("codex-triage/score_dedup: single-flight remote claim=" .. tostring(claim_key)
          .. " stage=" .. tostring(claim_stage) .. " - raising NO candidates this tick.")
        return nil
      end
    end
  end

  local cap = tonumber(core.read_env("FKST_TRIAGE_MAX_CANDIDATES")) or 5
  local slots = cap
  if cap > 0 and core.remote_claims_enabled() then
    local active = core.active_remote_claim_count(remote)
    slots = cap - active
    log.info(string.format(
      "codex-triage/score_dedup: active remote claims=%d cap=%d slots=%d",
      active, cap, slots))
    if slots <= 0 then
      log.info(string.format(
        "codex-triage/score_dedup: active remote claims=%d cap=%d - raising NO candidates this tick.",
        active, cap))
      return nil
    end
  end

  -- Small payloads only: {source_ref, dedup_key, schema, score}. NEVER the body -
  -- the consumer re-fetches via source_ref. A candidate is skipped when EITHER ledger
  -- (local outcome, remote control issue) already settles or claims it.
  local raised = 0
  for _, candidate in ipairs(candidates) do
    if slots > 0 and raised >= slots then break end
    local previous = latest[candidate.dedup_key]
    local locally_settled = previous ~= nil and core.outcome_is_final(previous)
    local remotely_claimed = remote[candidate.dedup_key] ~= nil
    if not locally_settled and not remotely_claimed then
      raise("codex_candidate", candidate)
      raised = raised + 1
    end
  end
  log.info(string.format("codex-triage/score_dedup: source=%s issues=%d candidates=%d raised=%d cap=%d slots=%d",
    source, #issues, #candidates, raised, cap, slots))

  return nil
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "score_dedup",
})
