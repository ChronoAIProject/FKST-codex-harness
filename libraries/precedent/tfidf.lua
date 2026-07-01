-- precedent: PURE TF-IDF similarity retrieval, the same lightweight similarity
-- used for clustering (docs/METHODOLOGY.md §7) and for retrieval-conditioned
-- generation at decision time (docs/learning-model.md §4): given a target issue
-- and a corpus, rank the nearest successful exemplars to feed `codex` as few-shot
-- context.
--
-- PURE: no os/io/network/exec, no global side effects. The CALLER supplies both
-- the target and the corpus (already read from disk / fetched); this library
-- only computes tokens, IDF, vectors, cosine, and the ranked top-k. It never
-- reads `data/` itself.
--
-- Model (METHODOLOGY §7):
--   text = title (weight x3) + body[:600]; tokens [a-z0-9]{3,}, stopwords dropped
--   idf  = log(N/df); term weight (1 + log(tf)) * idf; L2-normalized vectors
--   similarity = cosine; an optional categorical boost rewards corpus docs that
--   share the target's area / type (learning-model §4 area/type weighting).
local P = {}

-- A small, generic English stopword set (METHODOLOGY §7 "stopwords removed").
-- Kept deliberately conservative so domain terms survive.
local STOPWORDS = {}
do
  local words = {
    "the", "and", "for", "are", "but", "not", "you", "all", "any", "can",
    "her", "was", "one", "our", "out", "his", "has", "had", "him", "how",
    "its", "may", "new", "now", "old", "see", "two", "way", "who", "did",
    "get", "use", "this", "that", "with", "from", "have", "they", "will",
    "your", "what", "when", "been", "were", "them", "then", "than", "into",
    "some", "such", "only", "also", "does", "doing", "done", "here", "there",
    "would", "could", "should", "about", "which", "their", "while", "where",
  }
  for _, w in ipairs(words) do
    STOPWORDS[w] = true
  end
end

local TITLE_WEIGHT = 3 -- METHODOLOGY §7: title weighted x3.
local BODY_WINDOW = 600 -- METHODOLOGY §5/§7: body truncated to 600 chars.

-- tokenize(text) -> array of [a-z0-9]{3,} tokens with stopwords removed.
function P.tokenize(text)
  local out = {}
  if type(text) ~= "string" then
    return out
  end
  for token in text:lower():gmatch("[a-z0-9]+") do
    if #token >= 3 and not STOPWORDS[token] then
      table.insert(out, token)
    end
  end
  return out
end

-- issue_tokens(issue) -> the term-frequency map for one issue, with the title
-- counted TITLE_WEIGHT times and the body truncated to the 600-char window.
function P.issue_tokens(issue)
  local tf = {}
  if type(issue) ~= "table" then
    return tf
  end
  local title = type(issue.title) == "string" and issue.title or ""
  local body = type(issue.body) == "string" and string.sub(issue.body, 1, BODY_WINDOW) or ""
  for _ = 1, TITLE_WEIGHT do
    for _, token in ipairs(P.tokenize(title)) do
      tf[token] = (tf[token] or 0) + 1
    end
  end
  for _, token in ipairs(P.tokenize(body)) do
    tf[token] = (tf[token] or 0) + 1
  end
  return tf
end

-- build_idf(corpus) -> { N = doc_count, df = {...}, idf = {...} }.
-- df counts the number of corpus docs each token appears in; idf = log(N/df).
function P.build_idf(corpus)
  local df = {}
  local n = 0
  for _, issue in ipairs(corpus or {}) do
    n = n + 1
    local seen = {}
    for token in pairs(P.issue_tokens(issue)) do
      if not seen[token] then
        seen[token] = true
        df[token] = (df[token] or 0) + 1
      end
    end
  end
  local idf = {}
  for token, count in pairs(df) do
    -- log(N/df); a token present in every doc contributes ~0 (no discriminating
    -- power). N==0 yields an empty model and zero similarity everywhere.
    idf[token] = (n > 0) and math.log(n / count) or 0
  end
  return { N = n, df = df, idf = idf }
end

-- vectorize(tf, idf) -> an L2-normalized sparse {token = weight} vector, where
-- weight = (1 + log(tf)) * idf (METHODOLOGY §7). Tokens unknown to the idf model
-- (df==0) contribute nothing.
function P.vectorize(tf, idf)
  local vec = {}
  local sumsq = 0
  for token, count in pairs(tf or {}) do
    local token_idf = idf and idf[token]
    if token_idf and token_idf > 0 and count > 0 then
      local weight = (1 + math.log(count)) * token_idf
      if weight ~= 0 then
        vec[token] = weight
        sumsq = sumsq + weight * weight
      end
    end
  end
  if sumsq > 0 then
    local norm = math.sqrt(sumsq)
    for token, weight in pairs(vec) do
      vec[token] = weight / norm
    end
  end
  return vec
end

-- cosine(vec_a, vec_b) -> dot product of two L2-normalized sparse vectors, which
-- is their cosine similarity in [0, 1]. Iterates the smaller vector for speed.
function P.cosine(vec_a, vec_b)
  if type(vec_a) ~= "table" or type(vec_b) ~= "table" then
    return 0
  end
  local small, large = vec_a, vec_b
  -- (length comparison is best-effort; correctness holds either way)
  local count_a, count_b = 0, 0
  for _ in pairs(vec_a) do count_a = count_a + 1 end
  for _ in pairs(vec_b) do count_b = count_b + 1 end
  if count_b < count_a then
    small, large = vec_b, vec_a
  end
  local dot = 0
  for token, weight in pairs(small) do
    local other = large[token]
    if other then
      dot = dot + weight * other
    end
  end
  return dot
end

local function category(issue, field)
  if type(issue) == "table" and type(issue[field]) == "string" then
    return issue[field]
  end
  return nil
end

-- rank(target, corpus, opts) -> ranked array of
--   { issue = <corpus issue>, index = <1-based position in corpus>,
--     cosine = <text similarity>, score = <combined score> }
-- sorted by combined score descending, truncated to opts.k (default 5).
--
-- opts:
--   k            top-k cut (default 5; <=0 means "all")
--   area_weight  additive boost when target.area == corpus_doc.area (default 0)
--   type_weight  additive boost when target.type == corpus_doc.type (default 0)
--   min_cosine   drop docs below this raw text cosine before boosting (default 0)
--   self_ref     a value compared against each corpus doc's `ref`/`number`; the
--                matching doc is skipped so a target never retrieves itself
-- The categorical boosts implement learning-model §4 area/type weighting purely:
-- the caller tags issues with `area`/`type` (e.g. from `rubric`) and chooses the
-- weights; precedent itself stays decoupled from any specific scorer.
function P.rank(target, corpus, opts)
  opts = opts or {}
  local k = opts.k or 5
  local area_weight = opts.area_weight or 0
  local type_weight = opts.type_weight or 0
  local min_cosine = opts.min_cosine or 0
  local self_ref = opts.self_ref

  local idf = P.build_idf(corpus).idf
  local target_vec = P.vectorize(P.issue_tokens(target), idf)
  local target_area = category(target, "area")
  local target_type = category(target, "type")

  local ranked = {}
  for i, issue in ipairs(corpus or {}) do
    local is_self = false
    if self_ref ~= nil and type(issue) == "table" then
      if issue.ref == self_ref or issue.number == self_ref then
        is_self = true
      end
    end
    if not is_self then
      local cos = P.cosine(target_vec, P.vectorize(P.issue_tokens(issue), idf))
      if cos >= min_cosine then
        local combined = cos
        if area_weight ~= 0 and target_area ~= nil and category(issue, "area") == target_area then
          combined = combined + area_weight
        end
        if type_weight ~= 0 and target_type ~= nil and category(issue, "type") == target_type then
          combined = combined + type_weight
        end
        table.insert(ranked, { issue = issue, index = i, cosine = cos, score = combined })
      end
    end
  end

  table.sort(ranked, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    if a.cosine ~= b.cosine then
      return a.cosine > b.cosine
    end
    return a.index < b.index -- stable: earlier corpus position wins ties
  end)

  if k and k > 0 and #ranked > k then
    local top = {}
    for i = 1, k do
      top[i] = ranked[i]
    end
    return top
  end
  return ranked
end

return P
