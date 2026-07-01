-- rubric: the PURE METHODOLOGY scorer + dedup, the SINGLE implementation of the
-- selection rubric (docs/METHODOLOGY.md §3 R1, §5 the exact scoring function, §7
-- dedup, §8 funnel order). Shared library so `codex-triage/score_dedup` and the
-- learning model (`codex-learn/relearn`, docs/learning-model.md §7) score against
-- ONE definition rather than divergent copies.
--
-- PURE: no os/io/network/exec, no global side effects. Callers pass the already
-- -fetched issue table / parsed cluster array in; the library never reads disk.
-- Payload discipline (spec §6): the candidate payload carries only
-- {source_ref, schema, dedup_key, score} - NEVER the issue body.
local R = {}

-- ---------------------------------------------------------------------------
-- Area tiers (METHODOLOGY §3 R1). Embedded tier map keyed exactly to §3 so
-- callers/tests need no IO. `config` is Tier-A (METHODOLOGY §3/§8 key-areas
-- list); the B/C/D split refines the §3 prose with the data/area_rubric.json
-- fix-rate tiers.
-- ---------------------------------------------------------------------------
local TIER_A = {
  "exec", "regression", "tui", "mcp", "hooks", "custom-model", "documentation", "config",
}
local TIER_B = {
  "sandbox", "bug", "code-review", "subagent",
}
local TIER_C = {
  "tool-calls", "skills", "azure", "cli", "app-server", "enhancement",
  "performance", "session", "windows-os", "agent", "remote",
}
local TIER_D = {
  "context", "auth", "extension", "connectivity", "browser", "codex-web",
  "app", "rate-limits", "model-behavior", "computer-use", "safety-check",
}

local function build_set(list)
  local set = {}
  for _, name in ipairs(list) do
    set[name] = true
  end
  return set
end

local TIER_SETS = {
  A = build_set(TIER_A),
  B = build_set(TIER_B),
  C = build_set(TIER_C),
  D = build_set(TIER_D),
}

-- Hard-drop labels (METHODOLOGY §5: label in {safety-check, security} -> SKIP-security).
local SECURITY_LABELS = build_set({ "safety-check", "security" })

-- area_tier points (METHODOLOGY §5). D is a hard drop (handled before scoring).
local TIER_POINTS = { A = 40, B = 24, C = 12, unknown = 8, D = 0 }

-- ---------------------------------------------------------------------------
-- issue field normalizers (accept REST array-of-strings, REST array-of-objects,
-- or GraphQL {nodes={{name=...}}} label shapes; numeric or {total_count} reactions).
-- ---------------------------------------------------------------------------
function R.normalize_labels(issue)
  local out = {}
  if type(issue) ~= "table" then
    return out
  end
  local labels = issue.labels
  if type(labels) ~= "table" then
    return out
  end
  if type(labels.nodes) == "table" then
    labels = labels.nodes
  end
  for _, label in ipairs(labels) do
    local name
    if type(label) == "string" then
      name = label
    elseif type(label) == "table" then
      name = label.name
    end
    if type(name) == "string" then
      table.insert(out, name:lower())
    end
  end
  return out
end

local function has_label(labels, name)
  for _, label in ipairs(labels) do
    if label == name then
      return true
    end
  end
  return false
end

local function reactions_of(issue)
  if type(issue) ~= "table" then
    return 0
  end
  local r = issue.reactions
  if type(r) == "number" then
    return r
  end
  if type(r) == "table" then
    return tonumber(r.totalCount or r.total_count) or 0
  end
  return tonumber(r) or 0
end

local function body_of(issue)
  if type(issue) ~= "table" then
    return ""
  end
  local body = issue.body
  if type(body) == "string" then
    return body
  end
  return ""
end

local function issue_number(issue)
  if type(issue) ~= "table" then
    return nil
  end
  return tonumber(issue.number) or tonumber(issue.n)
end

-- Exposed (pure) field readers so consumers/tests can re-derive without reaching
-- into private helpers.
R.reactions_of = reactions_of
R.issue_number = issue_number

-- ---------------------------------------------------------------------------
-- Scoring components (METHODOLOGY §5)
-- ---------------------------------------------------------------------------

-- area_tier: best tier among the issue's labels (A > B > C > D), or "unknown".
-- A label is matched case-insensitively against the embedded tier sets.
function R.area_tier(labels)
  local best = nil
  for _, label in ipairs(labels) do
    if TIER_SETS.A[label] then
      return "A" -- A is the best possible; short-circuit.
    elseif TIER_SETS.B[label] then
      best = best or "B"
      if best == "C" or best == "D" then best = "B" end
    elseif TIER_SETS.C[label] then
      if best ~= "B" then best = "C" end
    elseif TIER_SETS.D[label] then
      best = best or "D"
    end
  end
  return best or "unknown"
end

-- type bonus + the derived issue_type (regression / bug / enhancement / other).
function R.type_bonus(labels, reactions)
  if has_label(labels, "regression") then
    return 24, "regression"
  elseif has_label(labels, "bug") then
    return 14, "bug"
  elseif has_label(labels, "enhancement") then
    if reactions >= 30 then
      return 12, "enhancement"
    elseif reactions >= 10 then
      return 6, "enhancement"
    end
    return 1, "enhancement"
  end
  return 6, "other"
end

-- anatomy: parsed from body[:600], cap 25. Returns (points, has_version).
function R.anatomy(body)
  local window = string.sub(tostring(body or ""), 1, 600):lower()
  local points = 0
  local has_version = false
  if window:find("version", 1, true) or window:find("%d+%.%d+%.%d+") then
    points = points + 5
    has_version = true
  end
  if window:find("repro", 1, true) or window:find("steps to", 1, true) then
    points = points + 8
  end
  if window:find("```", 1, true) then
    points = points + 4
  end
  if window:find("macos", 1, true) or window:find("windows", 1, true) or window:find("linux", 1, true) then
    points = points + 3
  end
  if window:find("error", 1, true) or window:find("panic", 1, true)
    or window:find("stack", 1, true) or window:find("exception", 1, true) then
    points = points + 5
  end
  if points > 25 then
    points = 25
  end
  return points, has_version
end

-- demand: min(reactions,40)/40 * 8.
function R.demand(reactions)
  local r = tonumber(reactions) or 0
  if r < 0 then r = 0 end
  if r > 40 then r = 40 end
  return r / 40 * 8
end

-- classify: the §5 bin gate. Pure over the four decision inputs so the bin
-- thresholds (58/45/32) are directly testable at the boundaries.
function R.classify(score, tier, issue_type, repro_ok)
  local attemptable_tier = (tier == "A" or tier == "B")
  local attemptable_type = (issue_type == "bug" or issue_type == "regression")
  if score >= 58 and attemptable_tier and attemptable_type and repro_ok then
    return "ATTEMPT"
  elseif score >= 45 then
    return "CANDIDATE"
  elseif score >= 32 then
    return "LOW"
  end
  return "SKIP"
end

-- score(issue) -> { score, bin, breakdown, skip_reason }
-- Implements METHODOLOGY §5 verbatim, including the two hard drops.
function R.score(issue)
  local labels = R.normalize_labels(issue)
  local reactions = reactions_of(issue)

  -- HARD DROP 1: security/safety -> route to security@openai.com (never public).
  for _, label in ipairs(labels) do
    if SECURITY_LABELS[label] then
      return {
        score = 0,
        bin = "SKIP",
        skip_reason = "SKIP-security",
        breakdown = { area_tier = 0, type = 0, anatomy = 0, demand = 0, tier = R.area_tier(labels) },
      }
    end
  end

  local tier = R.area_tier(labels)

  -- HARD DROP 2: best area tier == D (graveyard).
  if tier == "D" then
    return {
      score = 0,
      bin = "SKIP",
      skip_reason = "SKIP-tierD",
      breakdown = { area_tier = 0, type = 0, anatomy = 0, demand = 0, tier = "D" },
    }
  end

  local area_points = TIER_POINTS[tier] or 8
  local type_points, issue_type = R.type_bonus(labels, reactions)
  local anatomy_points, has_version = R.anatomy(body_of(issue))
  local demand_points = R.demand(reactions)
  local repro_ok = (anatomy_points >= 8) or has_version

  local total = area_points + type_points + anatomy_points + demand_points
  local bin = R.classify(total, tier, issue_type, repro_ok)

  return {
    score = total,
    bin = bin,
    skip_reason = nil,
    breakdown = {
      area_tier = area_points,
      type = type_points,
      anatomy = anatomy_points,
      demand = demand_points,
      tier = tier,
      issue_type = issue_type,
      has_version = has_version,
      repro_ok = repro_ok,
    },
  }
end

-- ---------------------------------------------------------------------------
-- Dedup (METHODOLOGY §7): collapse cluster members to the representative.
-- The representative is the member with the MOST reactions (ties broken by the
-- smallest issue number, for determinism). Pure given a parsed cluster array
-- (data/open_issue_clusters.json), so callers/tests need no IO.
-- ---------------------------------------------------------------------------

-- cluster_index(clusters) -> { [member_number] = representative_number }
function R.cluster_index(clusters)
  local index = {}
  if type(clusters) ~= "table" then
    return index
  end
  for _, cluster in ipairs(clusters) do
    local members = type(cluster) == "table" and cluster.members or nil
    if type(members) == "table" then
      local rep_n, rep_reactions = nil, nil
      for _, member in ipairs(members) do
        local n = tonumber(member.n) or tonumber(member.number)
        local rc = tonumber(member.reactions) or 0
        if n ~= nil then
          if rep_n == nil or rc > rep_reactions or (rc == rep_reactions and n < rep_n) then
            rep_n, rep_reactions = n, rc
          end
        end
      end
      if rep_n ~= nil then
        for _, member in ipairs(members) do
          local n = tonumber(member.n) or tonumber(member.number)
          if n ~= nil then
            index[n] = rep_n
          end
        end
      end
    end
  end
  return index
end

-- dedup_key(issue, index, repo) -> stable cluster key. Collapses any member to
-- its representative; issues outside every cluster are their own representative.
function R.dedup_key(issue, index, repo)
  repo = repo or "openai/codex"
  local n = issue_number(issue)
  local rep = n
  if index ~= nil and n ~= nil and index[n] ~= nil then
    rep = index[n]
  end
  return string.format("codex-triage:dup:%s#%s", tostring(repo), tostring(rep))
end

-- is_cluster_representative: only representatives are raised (duplicates collapse
-- onto them). An issue in no cluster is trivially its own representative.
function R.is_cluster_representative(issue, index)
  local n = issue_number(issue)
  if n == nil then
    return true
  end
  if index == nil or index[n] == nil then
    return true
  end
  return index[n] == n
end

-- ---------------------------------------------------------------------------
-- Candidate payload (the FROZEN codex_candidate contract)
-- ---------------------------------------------------------------------------

-- Stable pointer the consumer re-fetches the full issue through (no body inline).
function R.candidate_source_ref(repo, number)
  return { kind = "external", ref = string.format("%s#issues/%s", tostring(repo), tostring(number)) }
end

-- candidate_payload -> the SMALL, FROZEN payload {source_ref, dedup_key, schema, score}.
-- The sibling codex-saga consumes codex-triage.codex_candidate with exactly this shape.
-- source_ref points at the CHOSEN issue (the one we will actually work); dedup_key
-- collapses to the cluster representative key so duplicate members share one key.
function R.candidate_payload(repo, issue, scored, index)
  local number = issue_number(issue)
  return {
    schema = "codex-triage.candidate.v1",
    source_ref = R.candidate_source_ref(repo, number),
    dedup_key = R.dedup_key(issue, index, repo),
    score = scored.score,
  }
end

-- attempt_candidates: the full METHODOLOGY funnel in the CORRECT order (§8):
--   score+bin EVERY issue -> take the ATTEMPT set -> THEN dedup by cluster.
-- Returns one frozen payload per cluster-key that has >=1 ATTEMPT member. A
-- cluster is NEVER dropped merely because its most-reacted representative did not
-- itself bin ATTEMPT. Within a cluster we choose the representative when it is
-- itself ATTEMPT, otherwise the highest-scoring ATTEMPT member (ties broken by
-- more reactions, then smaller number, for determinism). Pure: no network/IO.
function R.attempt_candidates(issues, index, repo)
  repo = repo or "openai/codex"
  local order = {} -- cluster keys in first-ATTEMPT-appearance order (deterministic)
  local groups = {} -- key -> { entries = {...} }

  for _, issue in ipairs(issues or {}) do
    local scored = R.score(issue)
    if scored.bin == "ATTEMPT" then
      local key = R.dedup_key(issue, index, repo)
      local group = groups[key]
      if group == nil then
        group = { entries = {} }
        groups[key] = group
        table.insert(order, key)
      end
      table.insert(group.entries, {
        issue = issue,
        scored = scored,
        is_rep = R.is_cluster_representative(issue, index),
        number = issue_number(issue) or 0,
        reactions = reactions_of(issue),
      })
    end
  end

  local function better(challenger, incumbent)
    if incumbent == nil then
      return true
    end
    if challenger.scored.score ~= incumbent.scored.score then
      return challenger.scored.score > incumbent.scored.score
    end
    if challenger.reactions ~= incumbent.reactions then
      return challenger.reactions > incumbent.reactions
    end
    return challenger.number < incumbent.number
  end

  local payloads = {}
  for _, key in ipairs(order) do
    local chosen = nil
    for _, entry in ipairs(groups[key].entries) do
      if entry.is_rep then
        chosen = entry -- the representative is itself ATTEMPT; prefer it outright.
        break
      end
    end
    if chosen == nil then
      for _, entry in ipairs(groups[key].entries) do
        if better(entry, chosen) then
          chosen = entry
        end
      end
    end
    table.insert(payloads, R.candidate_payload(repo, chosen.issue, chosen.scored, index))
  end
  return payloads
end

return R
