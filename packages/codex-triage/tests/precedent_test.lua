-- libraries/precedent unit tests, exercised through this consuming package
-- (libraries do not host a runnable test target; the package-authoring guide's
-- prescribed mechanism is to cover a library via a consuming package's tests).
-- Asserts the PURE TF-IDF retrieval (METHODOLOGY §7 / learning-model §4): tokens
-- + stopwords, IDF, L2-normalized vectors, cosine, ranked top-k, and the
-- area/type categorical boost. No network/IO.
-- G5: every *_test.lua must yield >=1 passing engine test.
local precedent = require("precedent.tfidf")
local t = fkst.test

-- A tiny corpus of exemplar issues (shape: title/body[+area/type]).
local function corpus()
  return {
    { title = "exec panics after update", body = "codex exec crashes with a panic on macos", area = "exec", type = "regression" },
    { title = "mcp server handshake fails", body = "missing field sandboxPolicy in mcp startup", area = "mcp", type = "bug" },
    { title = "docs typo in readme", body = "the installation section has a small spelling mistake", area = "documentation", type = "bug" },
  }
end

return {
  -- tokenizer drops short tokens + stopwords, lowercases, keeps domain terms.
  test_tokenize_drops_stopwords_and_short_tokens = function()
    local tokens = precedent.tokenize("The codex EXEC is ok")
    -- "the"/"is" are stopwords; "ok" is <3 chars; "codex"/"exec" survive (lowercased).
    t.eq(#tokens, 2)
    t.eq(tokens[1], "codex")
    t.eq(tokens[2], "exec")
  end,

  -- title is weighted x3 in the term-frequency map (METHODOLOGY §7).
  test_issue_tokens_weights_title_thrice = function()
    local tf = precedent.issue_tokens({ title = "panic", body = "panic" })
    -- 3 from the title + 1 from the body.
    t.eq(tf["panic"], 4)
  end,

  -- cosine of a normalized vector with itself is 1; with a disjoint vector is 0.
  test_cosine_self_is_one_and_disjoint_is_zero = function()
    local idf = precedent.build_idf(corpus()).idf
    local v = precedent.vectorize(precedent.issue_tokens(corpus()[1]), idf)
    local self_cos = precedent.cosine(v, v)
    t.is_true(self_cos > 0.999 and self_cos < 1.001)
    t.eq(precedent.cosine({ alpha = 1.0 }, { beta = 1.0 }), 0)
  end,

  -- rank returns the most textually-similar exemplar first.
  test_rank_orders_by_text_similarity = function()
    local target = { title = "exec panic", body = "codex exec panic on macos after update" }
    local ranked = precedent.rank(target, corpus(), { k = 2 })
    t.eq(#ranked, 2)
    t.eq(ranked[1].issue.area, "exec") -- the exec/regression exemplar is nearest
    t.is_true(ranked[1].score >= ranked[2].score)
  end,

  -- the area boost can lift a same-area exemplar above a slightly closer one.
  test_rank_area_weight_boosts_same_area = function()
    local target = { title = "startup issue", body = "something fails", area = "mcp" }
    local docs = {
      { title = "exec startup issue", body = "something fails at startup", area = "exec" },
      { title = "mcp unrelated", body = "handshake negotiation problem", area = "mcp" },
    }
    local plain = precedent.rank(target, docs, { k = 2 })
    local boosted = precedent.rank(target, docs, { k = 2, area_weight = 1.0 })
    -- Without a boost the lexically-closer exec doc leads; the area boost flips it.
    t.eq(plain[1].issue.area, "exec")
    t.eq(boosted[1].issue.area, "mcp")
  end,

  -- self_ref keeps a target from retrieving itself out of the corpus.
  test_rank_skips_self_ref = function()
    local docs = {
      { ref = "openai/codex#1", title = "exec panic", body = "exec panic macos" },
      { ref = "openai/codex#2", title = "mcp bug", body = "mcp handshake" },
    }
    local ranked = precedent.rank({ title = "exec panic", body = "exec panic macos" }, docs, {
      k = 5,
      self_ref = "openai/codex#1",
    })
    for _, hit in ipairs(ranked) do
      t.is_true(hit.issue.ref ~= "openai/codex#1")
    end
  end,

  -- an empty corpus yields no exemplars (and no error).
  test_rank_empty_corpus_is_empty = function()
    t.eq(#precedent.rank({ title = "x", body = "y" }, {}, {}), 0)
  end,
}
