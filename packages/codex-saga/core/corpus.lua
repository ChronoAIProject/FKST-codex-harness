-- core.corpus: precedent reader over the worked-on corpus.
--
-- Payload discipline (spec §6): the corpus is NEVER inlined into a reliable payload.
-- The dossier department reads it back through the data pointer (data/ dir resolved
-- from FKST_SAGA_DATA_DIR, default "data") and selects a small precedent summary
-- (an analogous merged-PR fix) to cite (playbook §4: "cite their precedent").
local S = {}

local CORPUS_FILE = "worked_on_full.jsonl"

function S.install(M)
  function M.corpus_path()
    local dir = M.env_or("FKST_SAGA_DATA_DIR", "data")
    return dir .. "/" .. CORPUS_FILE
  end

  -- Decode the JSONL corpus text into an array of records. Malformed lines are
  -- skipped (best-effort); returns {} for empty/absent text.
  function M.decode_corpus(text)
    local records = {}
    if type(text) ~= "string" or text == "" then
      return records
    end
    for line in text:gmatch("[^\n]+") do
      local trimmed = M.trim(line)
      if trimmed ~= nil and trimmed ~= "" then
        local ok, record = pcall(json.decode, trimmed)
        if ok and type(record) == "table" then
          table.insert(records, record)
        end
      end
    end
    return records
  end

  -- Read + decode the corpus from disk. Degrades gracefully (returns {}) when the
  -- data file is absent or unreadable, so the saga still proceeds without precedent.
  function M.read_corpus()
    local path = M.corpus_path()
    if not file.exists(path) then
      return {}
    end
    local ok, text = pcall(file.read, path)
    if not ok then
      return {}
    end
    return M.decode_corpus(text)
  end

  local function record_labels(record)
    local out = {}
    local labels = record.labels
    if type(labels) == "table" and type(labels.nodes) == "table" then
      for _, node in ipairs(labels.nodes) do
        if type(node) == "table" and type(node.name) == "string" then
          out[node.name] = true
        end
      end
    end
    return out
  end

  local function fixed_by_pr(record)
    local refs = record.closedByPullRequestsReferences
    return type(refs) == "table"
      and type(refs.nodes) == "table"
      and #refs.nodes >= 1
  end

  -- Select the strongest precedent: a corpus issue fixed by a linked PR that shares
  -- at least one label with the candidate. Returns {number, title} or nil.
  function M.select_precedent(records, candidate_labels)
    if type(records) ~= "table" then
      return nil
    end
    local wanted = {}
    for _, label in ipairs(candidate_labels or {}) do
      wanted[tostring(label)] = true
    end
    local fallback = nil
    for _, record in ipairs(records) do
      if type(record) == "table" and fixed_by_pr(record) then
        if fallback == nil then
          fallback = { number = record.number, title = record.title }
        end
        local labels = record_labels(record)
        for name, _ in pairs(wanted) do
          if labels[name] then
            return { number = record.number, title = record.title }
          end
        end
      end
    end
    return fallback
  end
end

return S
