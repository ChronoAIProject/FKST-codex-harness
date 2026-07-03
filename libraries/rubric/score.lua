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
--
-- Config injection (closing the learning loop): R.score / R.classify / R.area_tier /
-- R.attempt_candidates take an OPTIONAL rubric-config table (tiers / tier_points /
-- thresholds / component weights). ABSENT fields fall back to the committed §5 literals,
-- so a config-less call reproduces today's calibrated scores byte-for-byte. The IMPURE
-- consumer (codex-triage/core.lua) reads data/area_rubric.json and builds the config from
-- the re-derived tiers + the fitted selection_model, so codex-learn's re-learned weights
-- ACTUALLY influence selection instead of being shadow artifacts. This library only
-- APPLIES a config; it never reads disk, so it stays pure.
local R = {}

-- ---------------------------------------------------------------------------
-- Area tiers (METHODOLOGY §3 R1). Embedded literal tier map keyed exactly to §3 so a
-- config-less caller/test needs no IO. `config` is Tier-A (METHODOLOGY §3/§8 key-areas
-- list) and data/area_rubric.json is reconciled to tag it "A_target" to match; the B/C/D
-- split refines the §3 prose with the data/area_rubric.json fix-rate tiers. These literals
-- are the DEFAULT; an injected config.tiers (built from area_rubric.json) overrides them.
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

local DEFAULT_TIER_SETS = {
  A = build_set(TIER_A),
  B = build_set(TIER_B),
  C = build_set(TIER_C),
  D = build_set(TIER_D),
}

-- Hard-drop labels (METHODOLOGY §5: label in {safety-check, security} -> SKIP-security).
-- Security routing is a policy INVARIANT, not a fix-rate tier, so it stays a fixed literal
-- and is NEVER overridable by an injected/relearned rubric.
local SECURITY_LABELS = build_set({ "safety-check", "security" })

-- area_tier points (METHODOLOGY §5). D is a hard drop (handled before scoring).
local DEFAULT_TIER_POINTS = { A = 40, B = 24, C = 12, unknown = 8, D = 0 }

-- §5 bin thresholds (the funnel gates) and per-component multipliers. Defaults reproduce
-- the committed calibration; an injected config overrides them (see resolve_config).
local DEFAULT_THRESHOLDS = { attempt = 58, candidate = 45, low = 32 }
local DEFAULT_WEIGHTS = { area = 1.0, type = 1.0, anatomy = 1.0, demand = 1.0 }

local COMPONENT_KEYS = { "area", "type", "anatomy", "demand" }

-- Map data/area_rubric.json fix-rate tier TAGS -> METHODOLOGY §3 tier letters.
local TIER_TAG_TO_LETTER = {
  A_target = "A",
  B_good = "B",
  C_only_if_strong_evidence = "C",
  D_avoid_graveyard = "D",
}

-- The rubric-proportional prior the selection re-fit (codex-learn/core/fit.lua) initializes
-- from, and the METHODOLOGY §5 per-component maxima the fit normalizes against. A fitted
-- weight becomes a rubric multiplier RELATIVE to this prior (fitted / prior), then the
-- multipliers are re-normalized to be SCALE-PRESERVING (see weights_from_selection_model).
local FIT_WEIGHT_PRIOR = { area = 1.0, type = 0.6, anatomy = 0.5, demand = 0.2 }
local COMPONENT_MAX = { area = 40.0, type = 24.0, anatomy = 25.0, demand = 8.0 }

local function finite_positive(v)
  return v ~= nil and v == v and v ~= math.huge and v ~= -math.huge and v > 0
end

-- resolve_config(config) -> a fully-populated, memoized config. PURE. Every absent field
-- falls back to the committed §5 literals, so `score(issue)` / `score(issue, nil)` /
-- `score(issue, {})` reproduce the calibrated rubric byte-for-byte; a config that injects
-- relearned tiers/weights/thresholds changes the outcome. The library only APPLIES a
-- config -- the CONSUMER (codex-triage/core.lua) is the impure loader that reads
-- data/area_rubric.json and builds it, keeping this library pure.
local function resolve_config(config)
  if type(config) == "table" and config.__rubric_resolved then
    return config
  end
  local src = (type(config) == "table") and config or {}
  local src_tiers = (type(src.tiers) == "table") and src.tiers or {}
  local src_points = (type(src.tier_points) == "table") and src.tier_points or {}
  local src_thresholds = (type(src.thresholds) == "table") and src.thresholds or {}
  local src_weights = (type(src.weights) == "table") and src.weights or {}
  local weights = {}
  for _, k in ipairs(COMPONENT_KEYS) do
    local v = tonumber(src_weights[k])
    weights[k] = finite_positive(v) and v or DEFAULT_WEIGHTS[k]
  end
  return {
    __rubric_resolved = true,
    tiers = {
      A = src_tiers.A or DEFAULT_TIER_SETS.A,
      B = src_tiers.B or DEFAULT_TIER_SETS.B,
      C = src_tiers.C or DEFAULT_TIER_SETS.C,
      D = src_tiers.D or DEFAULT_TIER_SETS.D,
    },
    tier_points = {
      A = tonumber(src_points.A) or DEFAULT_TIER_POINTS.A,
      B = tonumber(src_points.B) or DEFAULT_TIER_POINTS.B,
      C = tonumber(src_points.C) or DEFAULT_TIER_POINTS.C,
      D = tonumber(src_points.D) or DEFAULT_TIER_POINTS.D,
      unknown = tonumber(src_points.unknown) or DEFAULT_TIER_POINTS.unknown,
    },
    thresholds = {
      attempt = tonumber(src_thresholds.attempt) or DEFAULT_THRESHOLDS.attempt,
      candidate = tonumber(src_thresholds.candidate) or DEFAULT_THRESHOLDS.candidate,
      low = tonumber(src_thresholds.low) or DEFAULT_THRESHOLDS.low,
    },
    weights = weights,
  }
end
R.resolve_config = resolve_config

-- default_config() -> the committed literal config (handy for tests + callers that want to
-- start from the calibration and override a single field). PURE.
function R.default_config()
  return resolve_config(nil)
end

-- tier_sets_from_rubric(rubric) -> {A={name=true,...},B,C,D} lowercased tier sets built
-- from a DECODED area_rubric.json (rubric.areas[name].tier tag). PURE (no IO). Returns nil
-- when no usable areas map is present, so the caller keeps the literal defaults.
function R.tier_sets_from_rubric(rubric)
  if type(rubric) ~= "table" or type(rubric.areas) ~= "table" then
    return nil
  end
  local sets = { A = {}, B = {}, C = {}, D = {} }
  local any = false
  for name, spec in pairs(rubric.areas) do
    local tag = (type(spec) == "table") and spec.tier or nil
    local letter = TIER_TAG_TO_LETTER[tostring(tag)]
    if letter ~= nil and type(name) == "string" then
      sets[letter][name:lower()] = true
      any = true
    end
  end
  if not any then
    return nil
  end
  return sets
end

-- weights_from_selection_model(sm) -> {area,type,anatomy,demand} rubric multipliers from a
-- fitted, ACCEPTED selection_model. PURE. Returns nil unless the model is ACCEPTED with
-- finite, positive weights (fail-safe: keep the committed unit weights rather than apply a
-- degenerate fit).
--
-- Mapping: each fitted weight becomes a relative emphasis m_k = fitted_w_k / prior_w_k (a
-- component the fit did not move stays 1.0). The m_k are then RE-NORMALIZED to be SCALE-
-- PRESERVING: the maximum attainable score Σ mult_k·COMPONENT_MAX_k is held invariant at
-- Σ COMPONENT_MAX_k (~97), so the weights only REDISTRIBUTE emphasis across components and
-- can NEVER inflate/deflate the overall score scale. That keeps the §5 bins (58/45/32) on
-- the same calibrated score scale without re-deriving thresholds - relative re-weighting can
-- still move an issue across a bin, but the axis itself is never rescaled (and a uniform
-- re-scale of all fitted weights is therefore a no-op, as it should be - only RELATIVE
-- differences carry signal).
--
-- HONEST SCOPE (not the accepted logit): this is a bounded, scale-preserving RE-EMPHASIS of
-- the calibrated §5 rubric-point scorer - NOT the fitted logistic model itself (which lives
-- in logit space with a bias term, over normalized features). codex-learn's §6 gate (AUC +
-- monotonic bins) validates that logit model; production applies this conservative re-
-- emphasis derived from its accepted weights. Running the accepted logit directly in
-- production (with fit-emitted score-space thresholds) is the fully §6-rigorous follow-up.
function R.weights_from_selection_model(sm)
  if type(sm) ~= "table" or sm.accepted ~= true or type(sm.weights) ~= "table" then
    return nil
  end
  local raw = {}
  local weighted_max, total_max = 0.0, 0.0
  for _, k in ipairs(COMPONENT_KEYS) do
    local fw = tonumber(sm.weights[k])
    local prior = FIT_WEIGHT_PRIOR[k]
    if not finite_positive(fw) or not finite_positive(prior) then
      return nil
    end
    raw[k] = fw / prior
    weighted_max = weighted_max + raw[k] * COMPONENT_MAX[k]
    total_max = total_max + COMPONENT_MAX[k]
  end
  if not finite_positive(weighted_max) then
    return nil
  end
  local scale = total_max / weighted_max -- hold the max attainable score invariant
  local out = {}
  for _, k in ipairs(COMPONENT_KEYS) do
    out[k] = raw[k] * scale
  end
  return out
end

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
-- A label is matched case-insensitively against the tier sets (config-injected or literal).
function R.area_tier(labels, config)
  local sets = resolve_config(config).tiers
  local best = nil
  for _, label in ipairs(labels) do
    if sets.A[label] then
      return "A" -- A is the best possible; short-circuit.
    elseif sets.B[label] then
      best = best or "B"
      if best == "C" or best == "D" then best = "B" end
    elseif sets.C[label] then
      if best ~= "B" then best = "C" end
    elseif sets.D[label] then
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

-- classify: the §5 bin gate. Pure over the four decision inputs; the bin thresholds
-- (default 58/45/32, config-overridable) are directly testable at the boundaries.
function R.classify(score, tier, issue_type, repro_ok, config)
  local th = resolve_config(config).thresholds
  local attemptable_tier = (tier == "A" or tier == "B")
  local attemptable_type = (issue_type == "bug" or issue_type == "regression")
  if score >= th.attempt and attemptable_tier and attemptable_type and repro_ok then
    return "ATTEMPT"
  elseif score >= th.candidate then
    return "CANDIDATE"
  elseif score >= th.low then
    return "LOW"
  end
  return "SKIP"
end

-- score(issue[, config]) -> { score, bin, breakdown, skip_reason }
-- Implements METHODOLOGY §5 verbatim, including the two hard drops. `config` (optional)
-- injects relearned tiers/tier_points/thresholds/weights; absent -> the committed literals.
function R.score(issue, config)
  local cfg = resolve_config(config)
  local labels = R.normalize_labels(issue)
  local reactions = reactions_of(issue)

  -- HARD DROP 1: security/safety -> route to security@openai.com (never public).
  for _, label in ipairs(labels) do
    if SECURITY_LABELS[label] then
      return {
        score = 0,
        bin = "SKIP",
        skip_reason = "SKIP-security",
        breakdown = { area_tier = 0, type = 0, anatomy = 0, demand = 0, tier = R.area_tier(labels, cfg) },
      }
    end
  end

  local tier = R.area_tier(labels, cfg)

  -- HARD DROP 2: best area tier == D (graveyard).
  if tier == "D" then
    return {
      score = 0,
      bin = "SKIP",
      skip_reason = "SKIP-tierD",
      breakdown = { area_tier = 0, type = 0, anatomy = 0, demand = 0, tier = "D" },
    }
  end

  local area_points = cfg.tier_points[tier] or cfg.tier_points.unknown or 8
  local type_points, issue_type = R.type_bonus(labels, reactions)
  local anatomy_points, has_version = R.anatomy(body_of(issue))
  local demand_points = R.demand(reactions)
  local repro_ok = (anatomy_points >= 8) or has_version

  -- Per-component multipliers (default 1.0 == committed calibration; a relearned
  -- selection_model re-weights the emphasis). breakdown keeps the RAW §5 component points
  -- so the fit's feature space (codex-learn/core/fit.lua) + downstream normalization
  -- (codex-saga progress) stay stable regardless of the weighting.
  local w = cfg.weights
  local total = w.area * area_points + w.type * type_points
    + w.anatomy * anatomy_points + w.demand * demand_points
  local bin = R.classify(total, tier, issue_type, repro_ok, cfg)

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
-- more reactions, then smaller number, for determinism). Pure: no network/IO. The optional
-- `config` (built by the consumer from data/area_rubric.json) is resolved ONCE and threaded
-- into every per-issue R.score, so a relearned rubric re-scores the whole funnel.
function R.attempt_candidates(issues, index, repo, config)
  repo = repo or "openai/codex"
  local cfg = resolve_config(config)
  local order = {} -- cluster keys in first-ATTEMPT-appearance order (deterministic)
  local groups = {} -- key -> { entries = {...} }

  for _, issue in ipairs(issues or {}) do
    local scored = R.score(issue, cfg)
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
