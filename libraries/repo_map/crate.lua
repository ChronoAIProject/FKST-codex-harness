-- repo_map: PURE area -> crate resolution. The harness learns the area->crate
-- layout of the target repo (docs/learning-model.md §2 `codex-repo-structure.md`,
-- e.g. `exec`->`codex-rs/exec`, `mcp`->`codex-mcp`) and `codex-saga/implement`
-- uses it to point the fix at the right crate (learning-model §7).
--
-- PURE: no os/io/network/exec, no global side effects. The map DATA is supplied
-- by the CALLER (loaded from disk / fetched / a literal table); this library only
-- normalizes and queries it. The map shape is a flat { [area] = crate } table,
-- optionally with a `default` key used as a catch-all fallback.
local RM = {}

local function normalize(area)
  if type(area) == "string" then
    return area:lower()
  end
  return nil
end

-- resolve(map, area) -> crate path for `area`, or the map's `default`, or nil.
-- Area lookup is case-insensitive. A non-table map or unknown area returns nil
-- (callers fail soft to "no known crate").
function RM.resolve(map, area)
  if type(map) ~= "table" then
    return nil
  end
  local key = normalize(area)
  if key ~= nil and map[key] ~= nil then
    return map[key]
  end
  -- case-insensitive scan for keys that were stored with mixed case
  if key ~= nil then
    for map_key, crate in pairs(map) do
      if type(map_key) == "string" and map_key:lower() == key then
        return crate
      end
    end
  end
  if map.default ~= nil and key ~= "default" then
    return map.default
  end
  return nil
end

-- has_area(map, area) -> true when `area` maps to a crate (ignoring `default`).
function RM.has_area(map, area)
  if type(map) ~= "table" then
    return false
  end
  local key = normalize(area)
  if key == nil or key == "default" then
    return false
  end
  if map[key] ~= nil then
    return true
  end
  for map_key in pairs(map) do
    if type(map_key) == "string" and map_key:lower() == key then
      return true
    end
  end
  return false
end

-- resolve_labels(map, labels) -> { area = <area>, crate = <crate> } for the FIRST
-- label (in order) that maps to a crate, else nil. This lets a caller pass an
-- issue's label list straight through and get the most-specific known crate.
function RM.resolve_labels(map, labels)
  if type(map) ~= "table" or type(labels) ~= "table" then
    return nil
  end
  for _, label in ipairs(labels) do
    if RM.has_area(map, label) then
      return { area = normalize(label), crate = RM.resolve(map, label) }
    end
  end
  return nil
end

-- areas(map) -> sorted array of known area keys (excluding `default`).
function RM.areas(map)
  local out = {}
  if type(map) ~= "table" then
    return out
  end
  for key in pairs(map) do
    if type(key) == "string" and key ~= "default" then
      table.insert(out, key)
    end
  end
  table.sort(out)
  return out
end

-- crates(map) -> sorted, de-duplicated array of crate paths (including `default`).
function RM.crates(map)
  local seen = {}
  local out = {}
  if type(map) ~= "table" then
    return out
  end
  for _, crate in pairs(map) do
    if type(crate) == "string" and not seen[crate] then
      seen[crate] = true
      table.insert(out, crate)
    end
  end
  table.sort(out)
  return out
end

return RM
