-- core.encode: a PURE JSON encoder + JSONL helpers.
--
-- The fixed SDK exposes `json.decode` only (JSON is the engine wire format; Lua
-- values leave the engine via `raise`, so there is no `json.encode`). relearn,
-- however, must SERIALIZE the distilled banks (area_rubric.json, the relearn_log
-- rows, the rubric_history snapshots). So we hand-roll a small, deterministic
-- encoder here. PURE: no os/io/network, no globals.
local S = {}

function S.install(M)
  -- An explicit JSON `null` sentinel. Lua tables cannot store a nil value (the key
  -- just vanishes), so to emit `"auc": null` for a rejected cycle with undefined AUC
  -- we store this marker instead of nil.
  M.json_null = setmetatable({}, { __jsonnull = true })

  -- Tag a Lua table as a JSON array so it serializes as `[...]` even when empty.
  -- Sequences with >=1 contiguous integer key auto-detect as arrays; only EMPTY
  -- arrays need this tag to avoid being emitted as `{}`.
  function M.as_array(t)
    t = t or {}
    return setmetatable(t, { __jsonarray = true })
  end

  local function is_array(t)
    local mt = getmetatable(t)
    if mt and mt.__jsonarray == true then
      return true
    end
    local n = 0
    for _ in pairs(t) do
      n = n + 1
    end
    if n == 0 then
      return false -- untagged empty table => object `{}`
    end
    -- contiguous 1..n integer keys => array
    for i = 1, n do
      if t[i] == nil then
        return false
      end
    end
    return true
  end

  local ESCAPES = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
  }

  local function encode_string(s)
    local out = s:gsub('["\\%z\1-\31]', function(ch)
      local mapped = ESCAPES[ch]
      if mapped then
        return mapped
      end
      return string.format("\\u%04x", string.byte(ch))
    end)
    return '"' .. out .. '"'
  end

  local function encode_number(v)
    if v ~= v or v == math.huge or v == -math.huge then
      return "null" -- NaN / +-Inf are not valid JSON
    end
    if math.type and math.type(v) == "integer" then
      return string.format("%d", v)
    end
    -- %.10g keeps a stable, compact float form (e.g. AUC 0.733333333)
    return string.format("%.10g", v)
  end

  -- Sorted object keys keep snapshots/log rows byte-deterministic for review.
  local function sorted_keys(t)
    local keys = {}
    for k in pairs(t) do
      keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    return keys
  end

  local encode_value -- forward decl

  local function encode_table(t, parts)
    if is_array(t) then
      parts[#parts + 1] = "["
      local n = 0
      for _ in pairs(t) do
        n = n + 1
      end
      for i = 1, n do
        if i > 1 then
          parts[#parts + 1] = ","
        end
        encode_value(t[i], parts)
      end
      parts[#parts + 1] = "]"
      return
    end
    parts[#parts + 1] = "{"
    local first = true
    for _, key in ipairs(sorted_keys(t)) do
      if not first then
        parts[#parts + 1] = ","
      end
      first = false
      parts[#parts + 1] = encode_string(key)
      parts[#parts + 1] = ":"
      encode_value(t[key], parts)
    end
    parts[#parts + 1] = "}"
  end

  encode_value = function(v, parts)
    local tv = type(v)
    if v == nil then
      parts[#parts + 1] = "null"
    elseif tv == "boolean" then
      parts[#parts + 1] = v and "true" or "false"
    elseif tv == "number" then
      parts[#parts + 1] = encode_number(v)
    elseif tv == "string" then
      parts[#parts + 1] = encode_string(v)
    elseif tv == "table" then
      local mt = getmetatable(v)
      if mt and mt.__jsonnull == true then
        parts[#parts + 1] = "null"
      else
        encode_table(v, parts)
      end
    else
      error("codex-learn: cannot JSON-encode value of type " .. tv)
    end
  end

  -- json_encode(value) -> compact JSON string (objects key-sorted for determinism).
  function M.json_encode(value)
    local parts = {}
    encode_value(value, parts)
    return table.concat(parts)
  end

  -- decode_jsonl(text) -> array of decoded records. Malformed/blank lines skipped.
  function M.decode_jsonl(text)
    local records = {}
    if type(text) ~= "string" or text == "" then
      return records
    end
    for line in text:gmatch("[^\n]+") do
      local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
      if trimmed ~= "" then
        local ok, record = pcall(json.decode, trimmed)
        if ok and type(record) == "table" then
          records[#records + 1] = record
        end
      end
    end
    return records
  end
end

return S
