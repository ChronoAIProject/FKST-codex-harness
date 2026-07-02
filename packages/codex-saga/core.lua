-- codex-saga shared pure logic (require-able as `core`).
--
-- fkst.toml conformance hook: function = "core.saga_conformance_errors". The engine
-- require("core")s then calls core.saga_conformance_errors() with no args during
-- `conformance`; it MUST return an array table (empty = pass, a non-empty array of
-- {id, message} records = saga invariant violations). See core/saga_table.lua.
--
-- Responsibility split (1000-line cap; one topic per file):
--   core/strings.lua    bounded-string + marker-safe predicates
--   core/markers.lua    bot-authored GitHub marker builders (durable saga truth)
--   core/egress.lua     OWNED gh/git egress (mirrors github-proxy): dry-run by
--                       default, real only under FKST_GITHUB_WRITE=1, marker-gated
--   core/consensus.lua  OWNED multi-angle consensus approval hook (mirrors consensus)
--   core/corpus.lua     precedent corpus reader (data/worked_on_full.jsonl via path)
--   core/invite.lua     maintainer-invite re-derivation + volume-cap counting
--   core/dossier.lua    outward issue/comment + PR body builders (use t())
--   core/diagnose.lua   reproduce prompt + root-cause parsing + fork reproduction
--   core/implement.lua  WRITE-CLASS fix step: precedent.tfidf retrieval +
--                       repo_map.crate resolution + dry-run/real codex fix-write
--   core/engagement.lua retrieval-conditioned engagement learning: precedent.tfidf
--                       over corpus_engagement + induced engagement_styleguide rules
--   core/track.lua      terminal recorder: outcome (§5) schema + GitHub mirror +
--                       learning-field carry helper
--   core/outcomes_store.lua durable APPEND-ONLY outcomes JSONL channel codex-learn
--                       reads (path resolution + §5 JSON encoder + reader)
--   core/deliberation.lua durable capture of the gate's per-angle/dissent verdicts +
--                       refusal records + funnel stats (retrievable in dry-run)
--   core/outcome.lua    READ-ONLY closing-PR outcome re-derivation (closed feedback)
--   core/saga_table.lua restart_transition_table + saga_conformance_errors
local M = {}

local function getenv_raw(name)
  if type(os) == "table" and type(os.getenv) == "function" then
    return os.getenv(name)
  end
  return nil
end

function M.trim(value)
  if value == nil then
    return nil
  end
  return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Read a host env fact (config from .fkst/env). The engine package Lua state
-- exposes the safe `os` table (os.getenv); see the substrate example package.
-- Returns nil for unset or empty so callers fall back to a safe default posture.
function M.read_env(name)
  local raw = getenv_raw(name)
  if raw == nil then
    return nil
  end
  local s = M.trim(raw)
  if s == "" then
    return nil
  end
  return s
end

function M.env_or(name, default)
  local v = M.read_env(name)
  if v == nil then
    return default
  end
  return v
end

-- Two-plane targets (spec §4). Defaults are the documented program targets and are
-- only ever used for dry-run logging; real runs set them in .fkst/env.
function M.contrib_target()
  return M.env_or("FKST_CONTRIB_TARGET", "openai/codex")
end

function M.fork_repo()
  return M.env_or("FKST_GITHUB_REPO", "ChronoAIProject/codex")
end

-- The saga control issues live on THIS harness repo's tracker (spec §5/§6), which
-- is distinct from the contrib target and the fork.
function M.tracker_repo()
  return M.env_or("FKST_SAGA_TRACKER_REPO", "ChronoAIProject/FKST-codex-harness")
end

function M.fork_local_path()
  return M.read_env("FKST_FORK_LOCAL_PATH")
end

function M.bot_login()
  return M.read_env("FKST_GITHUB_BOT_LOGIN")
end

-- once()/lock key for a per-candidate saga step. once() is an in-runtime debounce
-- only (<RT>/marks is scratch); the durable idempotency truth is a bot-authored
-- GitHub marker on the relevant issue (see core/egress.lua + core/markers.lua).
-- The dedup_key carries ':' / '#' / '/' which are invalid runtime-key path
-- segments, so it is sanitized into a single safe segment (M.safe_segment).
function M.step_key(step, dedup_key)
  return "codex-saga/" .. M.safe_segment(step) .. "/" .. M.safe_segment(dedup_key)
end

-- Parse a candidate source_ref ({kind="external", ref="<repo>#issues/<n>"}) into
-- {repo, number}. Returns nil when the ref is not a recognizable issue pointer.
function M.parse_entity_ref(source_ref)
  if type(source_ref) ~= "table" then
    return nil
  end
  local ref = source_ref.ref
  if type(ref) ~= "string" then
    return nil
  end
  local repo, number = ref:match("^(.-)#issues/(%d+)$")
  if repo == nil then
    repo, number = ref:match("^(.-)#(%d+)$")
  end
  if repo == nil or repo == "" or number == nil then
    return nil
  end
  return { repo = repo, number = number }
end

-- Re-raise pipeline failures with the department name attached (fail-loud, narrow
-- error_class) - the workflow.saga `wrap` hook.
function M.wrap_pipeline_failure(name, fn)
  return function(event)
    local ok, result = pcall(fn, event)
    if not ok then
      error(string.format("codex-saga/%s pipeline failure: %s", name, tostring(result)))
    end
    return result
  end
end

require("core.strings").install(M)
require("core.markers").install(M)
require("core.egress").install(M)
require("core.consensus").install(M)
require("core.corpus").install(M)
require("core.invite").install(M)
require("core.dossier").install(M)
require("core.progress").install(M)
require("core.diagnose").install(M)
require("core.implement").install(M)
require("core.engagement").install(M)
require("core.track").install(M)
require("core.outcomes_store").install(M)
require("core.deliberation").install(M)
require("core.outcome").install(M)
require("core.saga_table").install(M)

return M
