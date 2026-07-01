-- core.strings: bounded-string + marker-safe predicates (own-package private).
local S = {}

function S.install(M)
  function M.is_bounded_string(value, limit)
    return type(value) == "string" and #value >= 1 and #value <= (limit or 4096)
  end

  function M.is_nonempty_string(value)
    return type(value) == "string" and value ~= ""
  end

  -- A marker value must be a bounded string with no characters that could break the
  -- surrounding HTML comment marker (angle brackets, quotes, newlines).
  function M.is_marker_safe(value, limit)
    return M.is_bounded_string(value, limit)
      and tostring(value):find('[<>"\r\n]') == nil
  end

  -- Make an arbitrary value safe to embed in a filesystem path segment.
  function M.safe_segment(value)
    local safe = tostring(value or ""):gsub("[^%w._-]", "_")
    safe = safe:gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if safe == "" then
      return "empty"
    end
    return safe
  end
end

return S
