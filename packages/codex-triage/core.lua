-- codex-triage shared logic (require-able as `core`).
--
-- The SELECTION SCORER + DEDUP (METHODOLOGY.md §3 rubrics, §5 the exact scoring
-- function, §7 dedup, §8 funnel order) is NOT implemented here: it lives ONCE in
-- the shared PURE library `libraries/rubric` (docs/learning-model.md §7 maps
-- "retrieve + score" to `codex-triage/score_dedup` + `rubric`). core re-exports
-- the rubric surface so departments + tests keep calling `core.score(...)` etc.,
-- while `codex-learn/relearn` scores against the SAME definition. There is one
-- implementation of the scorer.
--
-- What still lives here is package-local and NOT pure-scorer logic: the pipeline
-- failure wrap, and the PRODUCTION poll/read helpers (read_env, poll_open_issues,
-- load_clusters) - the only side-effecting code, never exercised by the test
-- suite (the department's act() takes an injectable seam so tests drive it with
-- inline fixtures).
--
-- Payload discipline (spec §6): events carry only {source_ref, schema,
-- dedup_key, score} - NEVER the issue body. Bodies are read back via source_ref.
local M = {}

-- The scorer's single implementation. PURE: no network/IO, so the tests that
-- call core.score / core.area_tier / core.attempt_candidates / ... exercise the
-- library directly through this delegation.
local rubric = require("rubric.score")

-- ---------------------------------------------------------------------------
-- pipeline failure wrap (workflow.saga `wrap` hook; fail-loud)
-- ---------------------------------------------------------------------------
-- Re-raise pipeline failures with the department name attached so the engine's
-- L1 fail-closed path gets a greppable, narrow error_class (not a bare error).
function M.wrap_pipeline_failure(name, fn)
  return function(event)
    local ok, result = pcall(fn, event)
    if not ok then
      error(string.format("codex-triage/%s pipeline failure: %s", name, tostring(result)))
    end
    return result
  end
end

-- ---------------------------------------------------------------------------
-- Scorer + dedup re-export (single implementation in libraries/rubric).
-- METHODOLOGY §3 (area tiers) / §5 (score, hard drops, bins) / §7 (dedup) / §8
-- (attempt funnel order). Callers use core.* exactly as before.
-- ---------------------------------------------------------------------------
M.normalize_labels = rubric.normalize_labels
M.area_tier = rubric.area_tier
M.type_bonus = rubric.type_bonus
M.anatomy = rubric.anatomy
M.demand = rubric.demand
M.classify = rubric.classify
M.score = rubric.score
M.cluster_index = rubric.cluster_index
M.dedup_key = rubric.dedup_key
M.is_cluster_representative = rubric.is_cluster_representative
M.candidate_source_ref = rubric.candidate_source_ref
M.candidate_payload = rubric.candidate_payload
M.attempt_candidates = rubric.attempt_candidates

-- ---------------------------------------------------------------------------
-- PRODUCTION side-effecting helpers (never exercised by tests; the department
-- takes an injectable seam so the suite drives it with inline fixtures).
-- ---------------------------------------------------------------------------

-- read_env: env reads go through `printf` (no os.getenv in the restricted Lua),
-- matching the github-proxy pattern. Fails soft to nil.
function M.read_env(name)
  if type(exec_sync) ~= "function" then
    return nil
  end
  local ok, result = pcall(exec_sync, 'printf %s "$' .. tostring(name) .. '"')
  if ok and type(result) == "table" and tonumber(result.exit_code) == 0 then
    local value = result.stdout
    if type(value) == "string" and value ~= "" then
      return value
    end
  end
  return nil
end

-- contrib_target: the foreign read target (FKST_CONTRIB_TARGET), default openai/codex.
function M.contrib_target()
  return M.read_env("FKST_CONTRIB_TARGET") or "openai/codex"
end

-- normalize_issue_pages: flatten `gh api --paginate --slurp` page arrays into the
-- pure {number,title,body,labels,reactions} issue shape, dropping PRs.
function M.normalize_issue_pages(stdout)
  local issues = {}
  if type(stdout) ~= "string" or stdout == "" then
    return issues
  end
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    return issues
  end
  local ok, pages = pcall(json.decode, stdout)
  if not ok or type(pages) ~= "table" then
    return issues
  end
  for _, page in ipairs(pages) do
    if type(page) == "table" then
      for _, raw in ipairs(page) do
        if type(raw) == "table" and raw.pull_request == nil then
          local labels = {}
          if type(raw.labels) == "table" then
            for _, label in ipairs(raw.labels) do
              if type(label) == "table" and type(label.name) == "string" then
                table.insert(labels, label.name)
              elseif type(label) == "string" then
                table.insert(labels, label)
              end
            end
          end
          local reactions = 0
          if type(raw.reactions) == "table" then
            reactions = tonumber(raw.reactions.total_count) or 0
          end
          table.insert(issues, {
            number = raw.number,
            title = raw.title,
            body = raw.body or "",
            labels = labels,
            reactions = reactions,
          })
        end
      end
    end
  end
  return issues
end

-- poll_open_issues: read-only `gh` poll of the contrib target's open issues.
-- All gh egress goes through the argv adapter (exec_argv), never a raw command head.
function M.poll_open_issues(repo)
  if type(exec_argv) ~= "function" then
    error("codex-triage: issue poll requires exec_argv")
  end
  local endpoint = string.format("repos/%s/issues?state=open&per_page=100", repo)
  local result = exec_argv({ argv = { "gh", "api", "--paginate", "--slurp", endpoint }, timeout = 120 })
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    error("codex-triage: gh issue poll failed for " .. tostring(repo))
  end
  return M.normalize_issue_pages(result.stdout)
end

-- load_clusters: read the seed cluster corpus (data/open_issue_clusters.json) by
-- source_ref, never inlined. Fails soft to {} (degrades to no-dedup) so a missing
-- file never crashes the poll.
function M.load_clusters()
  if type(file) ~= "table" or type(file.read) ~= "function" then
    return {}
  end
  local path = M.read_env("FKST_TRIAGE_CLUSTERS_PATH") or "data/open_issue_clusters.json"
  local ok, text = pcall(function()
    return file.read(path)
  end)
  if not ok or type(text) ~= "string" or text == "" then
    return {}
  end
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    return {}
  end
  local ok2, parsed = pcall(json.decode, text)
  if not ok2 or type(parsed) ~= "table" then
    return {}
  end
  return parsed
end

return M
