-- codex-saga/implement: the WRITE-CLASS fix step (learning-model §1/§4/§7). Consumes
-- the diagnosed candidate, RETRIEVES the nearest merged-PR exemplars (precedent.tfidf
-- over corpus_pr_style), RESOLVES the target crate (repo_map.crate over the area->crate
-- map), builds a fix prompt, and writes the fix on a fork worktree. DRY-RUN by default
-- (no real push/commit unless FKST_GITHUB_WRITE=1); the genuinely-once write is gated
-- on once()/marker. Advances to dossier on success, drops to needs_info with a WHY
-- otherwise. Local + read-only to the public (the fork is the owned plane).
--
-- G-SAGA-HEAD: static spec table at file head (after requires, before any local fn).
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "codex_diagnosed" },
  produces = { "codex_implemented" },
  stall_window = "30s",
}

-- done(event) is cheap + side-effect-free; there is no durable implement fact before
-- the fork branch exists, and at-least-once re-delivery re-runs the idempotent write.
local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  local entity = payload.source_ref
  local dedup_key = payload.dedup_key
  local fork_path = core.fork_local_path()

  -- Writing a fix needs the fork checkout. Without it we cannot implement: drop to
  -- needs_info with a WHY (guaranteed terminal, no foreign-plane write).
  if not core.is_nonempty_string(fork_path) then
    log.warn("codex-saga/implement needs_info: " .. t("codex-saga.implement.needs_info_no_fork")
      .. " (set FKST_FORK_LOCAL_PATH)")
    return nil
  end

  -- Retrieve nearest merged-PR exemplars (pure TF-IDF; corpus read via the data
  -- pointer, NEVER inlined - only refs are carried forward) + resolve the crate.
  local crate = core.resolve_target_crate(payload.labels)
  local target = core.implement_target(payload, crate)
  local exemplars = core.retrieve_pr_exemplars(target)
  if crate ~= nil then
    log.info("codex-saga/implement crate=" .. tostring(crate.crate) .. " (area " .. tostring(crate.area) .. ")")
  end

  -- Build the fix prompt + write the fix (dry-run by default; no real commands).
  local prompt = core.build_fix_prompt(entity, payload.root_cause, crate, exemplars)
  local branch = "codex-saga/fix-" .. core.safe_segment(dedup_key)
  local result = core.implement_write({
    dedup_key = dedup_key,
    fork_path = fork_path,
    branch = branch,
    prompt = prompt,
    crate = crate,
    entity = entity,
  })

  if not result.ok then
    log.warn("codex-saga/implement needs_info: " .. t("codex-saga.implement.needs_info_no_fix"))
    return nil
  end

  local raised = {
    schema = "codex-saga.implemented.v1",
    source_ref = entity,
    dedup_key = dedup_key,
    score = payload.score,
    labels = payload.labels,
    root_cause = payload.root_cause,
    -- the real fix branch the dossier/PR reference, and the small learning metadata.
    demo_branch = branch,
    crate = result.crate,
    picked_score = payload.score,
    exemplars_used = core.exemplar_refs(exemplars),
  }
  raise("codex_implemented", raised)
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "implement",
})
