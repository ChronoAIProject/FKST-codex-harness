-- core.engagement: retrieval-conditioned ENGAGEMENT learning (learning-model §1/§4).
--
-- This is the loop that was produced-but-not-applied: codex-learn induces
-- data/learning/engagement_styleguide.md from data/corpus_engagement.jsonl, and this
-- module is how dossier/engage APPLY it - retrieve the top-k nearest SUCCESSFUL
-- engagement threads via precedent.tfidf over the engagement corpus, AND consume the
-- induced styleguide rules, then compose the engagement comment conditioned on both
-- ("comment the way these k contributors successfully commented on similar issues;
-- obey these rules"). The corpus has no title/body, so the doc text is synthesized
-- from the thread's move-shape (opening/repro/offer_to_implement/...) + outcome, and
-- only MERGED threads form the exemplar bank (learn from wins).
--
-- PURE retrieval (precedent.tfidf); the corpus/styleguide DATA is read via a path
-- (env overrides FKST_ENGAGEMENT_CORPUS / FKST_ENGAGEMENT_STYLEGUIDE; fixtures/text
-- injected in tests). Only exemplar REFS are ever carried forward (payload
-- discipline - never comment bodies/threads).
local S = {}

local precedent = require("precedent.tfidf")

local DEFAULT_K = 3

-- The induced engagement rules the styleguide encodes (learning-model §2). Used as a
-- fail-soft default when data/learning/engagement_styleguide.md is not yet produced.
local DEFAULT_RULES = {
  "Lead with the reproduction",
  "Cite the root cause at file:line",
  "Offer to implement the fix",
  "Ask the maintainer for direction",
  "Keep the comment concise (about 200 words)",
  "Disclose AI assistance",
}

function S.install(M)
  function M.default_engagement_rules()
    local out = {}
    for _, rule in ipairs(DEFAULT_RULES) do
      table.insert(out, rule)
    end
    return out
  end

  -- ---- corpus + styleguide source paths (production default; injectable) -------
  function M.engagement_corpus_path()
    local override = M.read_env("FKST_ENGAGEMENT_CORPUS")
    if M.is_nonempty_string(override) then
      return override
    end
    return M.env_or("FKST_SAGA_DATA_DIR", "data") .. "/corpus_engagement.jsonl"
  end

  function M.engagement_styleguide_path()
    local override = M.read_env("FKST_ENGAGEMENT_STYLEGUIDE")
    if M.is_nonempty_string(override) then
      return override
    end
    return M.env_or("FKST_SAGA_DATA_DIR", "data") .. "/learning/engagement_styleguide.md"
  end

  function M.read_engagement_corpus(opts)
    opts = opts or {}
    if opts.records ~= nil then
      return opts.records
    end
    local text = opts.text
    if text == nil then
      local path = opts.path or M.engagement_corpus_path()
      if not file.exists(path) then
        return {}
      end
      local ok, contents = pcall(file.read, path)
      if not ok then
        return {}
      end
      text = contents
    end
    return M.decode_corpus(text)
  end

  -- ---- styleguide rules --------------------------------------------------------
  -- Parse the induced rules from the markdown styleguide (bullet lines). Degrades to
  -- the built-in DEFAULT_RULES when the file is absent (codex-learn not run yet).
  function M.parse_styleguide_rules(text)
    local rules = {}
    for line in tostring(text or ""):gmatch("[^\n]+") do
      local bullet = line:match("^%s*[%-%*]%s+(.+)$")
      if bullet ~= nil then
        local rule = M.trim(bullet)
        if M.is_nonempty_string(rule) then
          table.insert(rules, rule)
        end
      end
    end
    return rules
  end

  function M.read_engagement_styleguide(opts)
    opts = opts or {}
    local text = opts.text
    if text == nil then
      local path = opts.path or M.engagement_styleguide_path()
      if file.exists(path) then
        local ok, contents = pcall(file.read, path)
        if ok then
          text = contents
        end
      end
    end
    local rules = M.parse_styleguide_rules(text)
    if #rules == 0 then
      return M.default_engagement_rules()
    end
    return rules
  end

  -- True when any induced rule mentions `keyword` (case-insensitive substring). The
  -- composer uses this so the comment's section set is driven by the induced rules.
  function M.styleguide_has(rules, keyword)
    local kw = tostring(keyword):lower()
    for _, rule in ipairs(rules or {}) do
      if tostring(rule):lower():find(kw, 1, true) ~= nil then
        return true
      end
    end
    return false
  end

  -- ---- exemplar docs + retrieval ----------------------------------------------
  -- Synthesize a precedent-friendly doc from a thread's move-shape + outcome (the
  -- corpus has no title/body); only MERGED threads are exemplars (learn from wins).
  function M.engagement_exemplar_doc(record)
    local ref = nil
    if type(record.source_ref) == "table" then
      ref = record.source_ref.ref
    end
    local kinds = {}
    for _, move in ipairs(record.thread_moves or {}) do
      if type(move) == "table" and type(move.kind) == "string" then
        table.insert(kinds, move.kind)
      end
    end
    local text = table.concat(kinds, " ") .. " " .. tostring(record.outcome or "")
    return {
      ref = ref,
      source_ref = record.source_ref,
      title = text,
      body = text,
      outcome = record.outcome,
      maintainer_reactions = record.maintainer_reactions,
      merged = (record.outcome == "merged"),
    }
  end

  function M.build_engagement_docs(records)
    local docs = {}
    for _, record in ipairs(records or {}) do
      if type(record) == "table" and record.outcome == "merged" then
        table.insert(docs, M.engagement_exemplar_doc(record))
      end
    end
    return docs
  end

  -- The retrieval target: the candidate's labels + root cause + the winning move
  -- template the induced styleguide implies, so retrieval ranks threads whose
  -- successful move-shape matches our intended engagement.
  function M.engagement_target(payload, rules)
    payload = payload or {}
    local parts = {}
    for _, label in ipairs(payload.labels or {}) do
      table.insert(parts, tostring(label))
    end
    if M.is_nonempty_string(payload.root_cause) then
      table.insert(parts, payload.root_cause)
    end
    table.insert(parts, "opening")
    if M.styleguide_has(rules, "repro") then
      table.insert(parts, "repro")
    end
    if M.styleguide_has(rules, "implement") then
      table.insert(parts, "offer_to_implement")
    end
    if M.styleguide_has(rules, "direction") then
      table.insert(parts, "ask_direction")
    end
    local text = table.concat(parts, " ")
    return { title = text, body = text }
  end

  -- Rank the nearest successful engagement threads; return a SMALL normalized list
  -- { {ref, source_ref, outcome, maintainer_reactions, cosine}, ... } (refs only).
  function M.retrieve_engagement_exemplars(target, opts)
    opts = opts or {}
    local docs = M.build_engagement_docs(M.read_engagement_corpus(opts))
    local ranked = precedent.rank(target, docs, { k = opts.k or DEFAULT_K })
    local out = {}
    for _, entry in ipairs(ranked) do
      local doc = entry.issue or {}
      table.insert(out, {
        ref = doc.ref,
        source_ref = doc.source_ref,
        outcome = doc.outcome,
        maintainer_reactions = doc.maintainer_reactions,
        cosine = entry.cosine,
      })
    end
    return out
  end

  function M.engagement_exemplar_refs(exemplars)
    local refs = {}
    for _, exemplar in ipairs(exemplars or {}) do
      local ref = exemplar.ref
      if ref == nil and type(exemplar.source_ref) == "table" then
        ref = exemplar.source_ref.ref
      end
      if M.is_nonempty_string(ref) then
        table.insert(refs, ref)
      end
    end
    return refs
  end
end

return S
