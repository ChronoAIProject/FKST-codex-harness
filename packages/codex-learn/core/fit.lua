-- core.fit: re-fit the SELECTION weights over corpus_selection, then evaluate the
-- METHODOLOGY §6 acceptance gate (AUC >= 0.70 AND monotonic per-bin win-rate).
--
-- "Learning" here is plain computation, NOT ML infra (docs/learning-model.md §0/§3):
-- a simple logistic fit by gradient descent over the rubric scorer's OWN feature
-- space. We reconstruct each labeled record into an issue and run it through the
-- SINGLE scorer (require "rubric.score") so the fitted weights live in the SAME
-- feature space the production scorer uses (METHODOLOGY §5: area_tier/type/anatomy/
-- demand). PURE: no os/io/network, no globals.
local S = {}

local rubric = require("rubric.score")

-- Rubric component maxima (METHODOLOGY §5) used to normalize features to ~[0,1] so
-- gradient descent is well-conditioned.
local AREA_MAX = 40.0
local TYPE_MAX = 24.0
local ANATOMY_MAX = 25.0
local DEMAND_MAX = 8.0

local AUC_MIN = 0.70 -- METHODOLOGY §6 acceptance gate.

function S.install(M)
  M.AUC_MIN = AUC_MIN

  -- Reconstruct an issue from a corpus_selection record so the SAME rubric scorer
  -- code path derives the feature components. anatomy_flags are rendered into a body
  -- the rubric's anatomy parser recognizes verbatim (version/repro/code/os/error).
  -- SAFE FALLBACK (#14): anatomy_flags and reactions are OPTIONAL - a record without them
  -- (e.g. a folded outcome before the saga populates them) trains anatomy/demand as 0; once
  -- relearn.fold_outcomes carries them through from the §5 outcome record they train for real.
  function M.synthesize_issue(record)
    local flags = (type(record) == "table" and record.anatomy_flags) or {}
    local parts = {}
    if flags.version then
      parts[#parts + 1] = "version 1.2.3"
    end
    if flags.repro then
      parts[#parts + 1] = "steps to reproduce"
    end
    if flags.code then
      parts[#parts + 1] = "```\ncode block\n```"
    end
    if flags.os then
      parts[#parts + 1] = "macos"
    end
    if flags.error then
      parts[#parts + 1] = "error panic stack exception"
    end
    local labels = {}
    if type(record) == "table" and type(record.area_labels) == "table" then
      for _, name in ipairs(record.area_labels) do
        labels[#labels + 1] = tostring(name):lower()
      end
    end
    return {
      labels = labels,
      reactions = (type(record) == "table" and tonumber(record.reactions)) or 0,
      body = table.concat(parts, "\n"),
    }
  end

  -- feature_vector(record) -> normalized {area, type, anatomy, demand} in ~[0,1],
  -- derived through the production scorer's breakdown.
  function M.feature_vector(record)
    local scored = rubric.score(M.synthesize_issue(record))
    local b = scored.breakdown or {}
    return {
      area = (tonumber(b.area_tier) or 0) / AREA_MAX,
      type = (tonumber(b.type) or 0) / TYPE_MAX,
      anatomy = (tonumber(b.anatomy) or 0) / ANATOMY_MAX,
      demand = (tonumber(b.demand) or 0) / DEMAND_MAX,
    }
  end

  -- label_of(record) -> 1 (win) | 0 (loss) | nil (unlabeled, excluded from the fit).
  function M.label_of(record)
    if type(record) ~= "table" then
      return nil
    end
    local l = record.label
    if l == "win" then
      return 1
    elseif l == "loss" then
      return 0
    end
    return nil
  end

  -- Build the parallel (feature, label) training arrays from a record corpus.
  function M.training_set(records)
    local feats, labels = {}, {}
    for _, record in ipairs(records or {}) do
      local y = M.label_of(record)
      if y ~= nil then
        feats[#feats + 1] = M.feature_vector(record)
        labels[#labels + 1] = y
      end
    end
    return feats, labels
  end

  local function sigmoid(z)
    if z >= 0 then
      return 1.0 / (1.0 + math.exp(-z))
    end
    local e = math.exp(z)
    return e / (1.0 + e)
  end

  local KEYS = { "area", "type", "anatomy", "demand" }

  -- logit(weights, feature) -> bias + sum w_k * f_k.
  local function logit(w, f)
    local z = w.bias
    for _, k in ipairs(KEYS) do
      z = z + (w[k] or 0) * (f[k] or 0)
    end
    return z
  end
  M.logit = logit

  -- fit_weights(feats, labels[, opts]) -> weights table {bias, area, type, anatomy,
  -- demand}. Plain logistic gradient descent (no ML libs). Initialized from a
  -- rubric-proportional prior so a degenerate corpus still yields sane weights.
  function M.fit_weights(feats, labels, opts)
    opts = opts or {}
    local iters = opts.iters or 800
    local lr = opts.lr or 0.5
    local l2 = opts.l2 or 1e-4
    local w = {
      bias = -1.0,
      area = 1.0,
      type = 0.6,
      anatomy = 0.5,
      demand = 0.2,
    }
    local n = #feats
    if n == 0 then
      return w
    end
    for _ = 1, iters do
      local g = { bias = 0, area = 0, type = 0, anatomy = 0, demand = 0 }
      for i = 1, n do
        local f = feats[i]
        local err = sigmoid(logit(w, f)) - labels[i]
        g.bias = g.bias + err
        for _, k in ipairs(KEYS) do
          g[k] = g[k] + err * (f[k] or 0)
        end
      end
      w.bias = w.bias - lr * (g.bias / n)
      for _, k in ipairs(KEYS) do
        w[k] = w[k] - lr * (g[k] / n + l2 * w[k])
      end
    end
    return w
  end

  -- auc(scores, labels) -> Mann-Whitney rank statistic in [0,1], or nil when either
  -- class is empty (AUC undefined). Ties contribute 0.5 (METHODOLOGY §6).
  function M.auc(scores, labels)
    local wins, losses = {}, {}
    for i, y in ipairs(labels) do
      if y == 1 then
        wins[#wins + 1] = scores[i]
      else
        losses[#losses + 1] = scores[i]
      end
    end
    if #wins == 0 or #losses == 0 then
      return nil
    end
    local concordant = 0
    for _, sw in ipairs(wins) do
      for _, sl in ipairs(losses) do
        if sw > sl then
          concordant = concordant + 1
        elseif sw == sl then
          concordant = concordant + 0.5
        end
      end
    end
    return concordant / (#wins * #losses)
  end

  -- bin_winrates(scores, labels[, nbins]) -> array of per-bin win-rate, LOW->HIGH
  -- score, over NON-EMPTY equal-width bins. This is the §6 "per-bin PR-linked rate".
  function M.bin_winrates(scores, labels, nbins)
    nbins = nbins or 4
    local lo, hi = math.huge, -math.huge
    for _, s in ipairs(scores) do
      if s < lo then
        lo = s
      end
      if s > hi then
        hi = s
      end
    end
    if #scores == 0 then
      return {}
    end
    local span = hi - lo
    local sums, counts = {}, {}
    for i = 1, nbins do
      sums[i], counts[i] = 0, 0
    end
    for i, s in ipairs(scores) do
      local idx
      if span <= 0 then
        idx = 1
      else
        idx = math.floor((s - lo) / span * nbins) + 1
        if idx > nbins then
          idx = nbins
        end
        if idx < 1 then
          idx = 1
        end
      end
      sums[idx] = sums[idx] + labels[i]
      counts[idx] = counts[idx] + 1
    end
    local rates = {}
    for i = 1, nbins do
      if counts[i] > 0 then
        rates[#rates + 1] = sums[i] / counts[i]
      end
    end
    return rates
  end

  -- is_monotonic(rates) -> true if non-decreasing within tolerance. A single bin
  -- (or none) is trivially monotonic.
  function M.is_monotonic(rates, tol)
    tol = tol or 1e-9
    for i = 2, #rates do
      if rates[i] < rates[i - 1] - tol then
        return false
      end
    end
    return true
  end

  -- evaluate(records[, opts]) -> the candidate selection model + its metrics.
  -- This is the §6 gate: ACCEPT iff AUC >= 0.70 AND per-bin win-rate monotonic AND
  -- both classes are present. The metrics are returned WHETHER OR NOT accepted, so a
  -- rejected cycle is fully visible in the relearn_log.
  function M.evaluate(records, opts)
    opts = opts or {}
    local feats, labels = M.training_set(records)
    local weights = M.fit_weights(feats, labels, opts)
    local scores = {}
    for i = 1, #feats do
      scores[i] = logit(weights, feats[i])
    end
    local auc = M.auc(scores, labels)
    local rates = M.bin_winrates(scores, labels, opts.nbins or 4)
    local monotonic = M.is_monotonic(rates)
    local n_win, n_loss = 0, 0
    for _, y in ipairs(labels) do
      if y == 1 then
        n_win = n_win + 1
      else
        n_loss = n_loss + 1
      end
    end
    local accepted = (auc ~= nil) and (auc >= AUC_MIN) and monotonic and (n_win > 0) and (n_loss > 0)
    return {
      accepted = accepted,
      auc = auc,
      monotonic = monotonic,
      bins = M.as_array(rates),
      weights = weights,
      counts = { win = n_win, loss = n_loss, total = n_win + n_loss, fit_records = #feats },
      gate = { auc_min = AUC_MIN, require_monotonic = true },
      feature_space = "rubric.score breakdown: area_tier/type/anatomy/demand (normalized)",
      method = "logistic gradient-descent (plain computation, no ML libs)",
    }
  end
end

return S
