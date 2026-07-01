-- core.styleguide: induce the engagement + PR styleguides from the corpora, and
-- re-rank the exemplar banks via precedent (docs/learning-model.md §3).
--
-- Engagement: cluster the MOVE-KINDS of successful issue threads into rules + keep
-- the highest-outcome threads as the exemplar bank. PR: extract conventions (size,
-- test, commits) from merged PRs. Exemplar re-rank uses precedent.tfidf centrality
-- + outcome credit (§5 credit assignment). PURE: no os/io/network, no globals.
local S = {}

local precedent = require("precedent.tfidf")

local CENTRALITY_CAP = 1500 -- skip O(n^2) centrality above this corpus size.

-- Map a successful-thread MOVE-KIND to the engagement rule it induces. Only kinds
-- actually observed in successful threads contribute, so the styleguide tracks what
-- earned traction rather than a fixed wishlist.
local KIND_RULES = {
  repro = "Lead with a concrete reproduction: repro steps plus version/OS.",
  offer_to_implement = "Offer to implement the fix yourself.",
  ask_direction = "Ask the maintainers for direction before implementing.",
  info_request = "Answer maintainer info-requests promptly and specifically.",
  confirm = "Confirm the diagnosis with evidence before proposing a change.",
}
-- Render order so identical inputs always produce byte-identical styleguides.
local KIND_ORDER = { "repro", "confirm", "offer_to_implement", "ask_direction", "info_request" }

local function ref_of(record)
  if type(record) == "table" and type(record.source_ref) == "table" then
    return record.source_ref.ref
  end
  return nil
end

local function median(values)
  local sorted = {}
  for _, v in ipairs(values) do
    sorted[#sorted + 1] = v
  end
  table.sort(sorted)
  local n = #sorted
  if n == 0 then
    return 0
  end
  if n % 2 == 1 then
    return sorted[(n + 1) // 2]
  end
  return (sorted[n // 2] + sorted[n // 2 + 1]) / 2
end

local function pct(part, whole)
  if whole == 0 then
    return 0
  end
  return math.floor((part / whole) * 100 + 0.5)
end

-- Round to the nearest integer for `%d` rendering (medians can be fractional).
local function round(value)
  return math.floor(tonumber(value) + 0.5)
end

function S.install(M)
  M.engagement_kind_rules = KIND_RULES

  -- ---------------------------------------------------------------------------
  -- Engagement styleguide
  -- ---------------------------------------------------------------------------
  function M.induce_engagement(records, outcomes)
    local kind_counts = {}
    local opening_words = {}
    local successful, total = 0, 0
    for _, record in ipairs(records or {}) do
      total = total + 1
      local is_success = record.outcome == "merged"
      if is_success then
        successful = successful + 1
      end
      for _, move in ipairs(record.thread_moves or {}) do
        if is_success and type(move.kind) == "string" then
          kind_counts[move.kind] = (kind_counts[move.kind] or 0) + 1
        end
        if move.kind == "opening" and tonumber(move.len_words) then
          opening_words[#opening_words + 1] = tonumber(move.len_words)
        end
      end
    end

    local rules = {}
    for _, kind in ipairs(KIND_ORDER) do
      if (kind_counts[kind] or 0) > 0 then
        rules[#rules + 1] = KIND_RULES[kind]
      end
    end
    -- Constant guardrail rules (METHODOLOGY R3 / spec §10): always present.
    rules[#rules + 1] = "Cite the root cause precisely as file:line."
    local opening_median = median(opening_words)
    local concise_target = opening_median > 0 and math.min(opening_median, 200) or 200
    rules[#rules + 1] = string.format("Keep the comment concise (around %d words).", round(concise_target))
    rules[#rules + 1] = "Disclose that the analysis is AI-assisted."

    local rerank = M.rerank_exemplars(records, "engagement", outcomes)
    return {
      rules = M.as_array(rules),
      move_kind_counts = kind_counts,
      opening_median_words = opening_median,
      successful = successful,
      total = total,
      exemplars = rerank.ranked,
      rerank_summary = rerank.summary,
    }
  end

  function M.render_engagement_md(induced)
    local out = {}
    out[#out + 1] = "# " .. t("codex-learn.styleguide.engagement.title")
    out[#out + 1] = ""
    out[#out + 1] = t("codex-learn.styleguide.engagement.preamble")
    out[#out + 1] = ""
    out[#out + 1] = string.format(
      "Induced from %d successful of %d threads. Rules:",
      induced.successful,
      induced.total
    )
    out[#out + 1] = ""
    for _, rule in ipairs(induced.rules) do
      out[#out + 1] = "- " .. rule
    end
    out[#out + 1] = ""
    out[#out + 1] = "## Exemplar bank (re-ranked)"
    for i, ex in ipairs(induced.exemplars) do
      if i > 10 then
        break
      end
      out[#out + 1] = string.format("%d. %s", i, tostring(ex.ref))
    end
    out[#out + 1] = ""
    return table.concat(out, "\n")
  end

  -- ---------------------------------------------------------------------------
  -- PR styleguide
  -- ---------------------------------------------------------------------------
  function M.induce_pr_style(records, outcomes)
    local merged_count, total = 0, 0
    local files_le_3, loc_le_200, has_test = 0, 0, 0
    local files, locs, commits = {}, {}, {}
    for _, record in ipairs(records or {}) do
      total = total + 1
      if record.merged == true then
        merged_count = merged_count + 1
        local cf = tonumber(record.changed_files) or 0
        local loc = (tonumber(record.additions) or 0) + (tonumber(record.deletions) or 0)
        files[#files + 1] = cf
        locs[#locs + 1] = loc
        commits[#commits + 1] = tonumber(record.commits) or 0
        if cf <= 3 then
          files_le_3 = files_le_3 + 1
        end
        if loc <= 200 then
          loc_le_200 = loc_le_200 + 1
        end
        if record.has_test == true then
          has_test = has_test + 1
        end
      end
    end

    local rules = M.as_array({
      string.format("Touch <=3 files (%d%% of merged PRs did).", pct(files_le_3, merged_count)),
      string.format("Keep the diff <=200 LOC (%d%% of merged PRs did).", pct(loc_le_200, merged_count)),
      string.format("Include a test (%d%% of merged PRs did).", pct(has_test, merged_count)),
      string.format("Keep it atomic: around %d commit(s) (median).", round(median(commits))),
    })

    local rerank = M.rerank_exemplars(records, "pr_style", outcomes)
    return {
      rules = rules,
      merged_count = merged_count,
      total = total,
      files_le_3_frac = merged_count > 0 and files_le_3 / merged_count or 0,
      loc_le_200_frac = merged_count > 0 and loc_le_200 / merged_count or 0,
      has_test_frac = merged_count > 0 and has_test / merged_count or 0,
      median_files = median(files),
      median_loc = median(locs),
      median_commits = median(commits),
      exemplars = rerank.ranked,
      rerank_summary = rerank.summary,
    }
  end

  function M.render_pr_md(induced)
    local out = {}
    out[#out + 1] = "# " .. t("codex-learn.styleguide.pr.title")
    out[#out + 1] = ""
    out[#out + 1] = t("codex-learn.styleguide.pr.preamble")
    out[#out + 1] = ""
    out[#out + 1] = string.format("Induced from %d merged of %d PRs. Rules:", induced.merged_count, induced.total)
    out[#out + 1] = ""
    for _, rule in ipairs(induced.rules) do
      out[#out + 1] = "- " .. rule
    end
    out[#out + 1] = ""
    out[#out + 1] = "## Exemplar bank (re-ranked, nearest merged diffs first)"
    for i, ex in ipairs(induced.exemplars) do
      if i > 10 then
        break
      end
      out[#out + 1] = string.format("%d. %s", i, tostring(ex.ref))
    end
    out[#out + 1] = ""
    return table.concat(out, "\n")
  end

  -- ---------------------------------------------------------------------------
  -- Exemplar pseudo-documents + re-rank (precedent.tfidf centrality + outcome credit)
  -- ---------------------------------------------------------------------------

  -- Convert a structured exemplar into a pseudo-issue {title, body} so precedent's
  -- TF-IDF (built for issue text) can rank representativeness over the bank.
  function M.exemplar_doc(record, kind)
    if kind == "engagement" then
      local kinds, roles = {}, {}
      for _, move in ipairs(record.thread_moves or {}) do
        if type(move.kind) == "string" then
          kinds[#kinds + 1] = move.kind
        end
        if type(move.role) == "string" then
          roles[#roles + 1] = move.role
        end
      end
      return { title = table.concat(kinds, " "), body = table.concat(roles, " ") .. " " .. tostring(record.outcome) }
    end
    -- pr_style: tokens from touched-path directories + author + size class.
    local dirs = {}
    for _, p in ipairs(record.touched_paths or {}) do
      local first = tostring(p):match("^([^/]+)")
      if first then
        dirs[#dirs + 1] = first
      end
      local second = tostring(p):match("^[^/]+/([^/]+)")
      if second then
        dirs[#dirs + 1] = second
      end
    end
    local size_class = ((tonumber(record.changed_files) or 0) <= 3) and "small_surgical" or "large_change"
    local test_tok = record.has_test == true and "has_test" or "no_test"
    return {
      title = table.concat(dirs, " "),
      body = string.format("%s %s %s", tostring(record.author_assoc), size_class, test_tok),
    }
  end

  -- base outcome score for an exemplar (the §5 "highest-outcome" ordering).
  local function base_outcome_score(record, kind)
    if kind == "engagement" then
      local s = 0
      if record.outcome == "merged" then
        s = 2
      elseif record.outcome == "closed" then
        s = 0.5
      end
      s = s + (tonumber(record.maintainer_reactions) or 0) * 0.1
      return s
    end
    return record.merged == true and 2 or 0
  end

  -- credit assignment from durable outcomes (§5): exemplars used by GOOD outcomes
  -- gain credit, those used by BAD outcomes lose it.
  local function credit_map(outcomes)
    local map = {}
    for _, oc in ipairs(outcomes or {}) do
      local disp = oc.disposition
      local good = (disp == "merged") or (oc.engagement_reaction == "invited") or (oc.engagement_reaction == "positive")
      local bad = (disp == "closed") or (disp == "ignored")
      local delta = good and 1 or (bad and -1 or 0)
      if delta ~= 0 then
        for _, ref in ipairs(oc.exemplars_used or {}) do
          map[tostring(ref)] = (map[tostring(ref)] or 0) + delta
        end
      end
    end
    return map
  end

  -- rerank_exemplars(records, kind[, outcomes]) -> { ranked = [{ref, score}...],
  -- summary = {...} }. Combines outcome score, outcome credit, and precedent
  -- TF-IDF centrality (how representative the exemplar is of the bank).
  function M.rerank_exemplars(records, kind, outcomes)
    records = records or {}
    local credit = credit_map(outcomes)

    local docs, vectors = {}, {}
    local use_centrality = #records > 0 and #records <= CENTRALITY_CAP
    if use_centrality then
      for i, record in ipairs(records) do
        docs[i] = M.exemplar_doc(record, kind)
      end
      local idf = precedent.build_idf(docs).idf
      for i, doc in ipairs(docs) do
        vectors[i] = precedent.vectorize(precedent.issue_tokens(doc), idf)
      end
    end

    local entries = {}
    local credited = 0
    for i, record in ipairs(records) do
      local ref = ref_of(record)
      local centrality = 0
      if use_centrality then
        for j = 1, #records do
          if j ~= i then
            centrality = centrality + precedent.cosine(vectors[i], vectors[j])
          end
        end
        if #records > 1 then
          centrality = centrality / (#records - 1)
        end
      end
      local c = credit[tostring(ref)] or 0
      if c ~= 0 then
        credited = credited + 1
      end
      entries[#entries + 1] = {
        ref = ref,
        index = i,
        score = base_outcome_score(record, kind) + c + 0.25 * centrality,
      }
    end

    table.sort(entries, function(a, b)
      if a.score ~= b.score then
        return a.score > b.score
      end
      return tostring(a.ref) < tostring(b.ref)
    end)

    local top = {}
    for i = 1, math.min(5, #entries) do
      top[i] = entries[i].ref
    end
    return {
      ranked = entries,
      summary = {
        kind = kind,
        method = "precedent.tfidf centrality + outcome credit",
        n = #entries,
        credited = credited,
        centrality = use_centrality,
        top = M.as_array(top),
      },
    }
  end
end

return S
