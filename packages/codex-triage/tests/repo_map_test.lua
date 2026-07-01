-- libraries/repo_map unit tests, exercised through this consuming package (the
-- guide's library-test mechanism). Asserts PURE area->crate resolution
-- (learning-model §2 codex-repo-structure.md / §7): case-insensitive lookup,
-- `default` fallback, first-matching-label resolution, and the area/crate
-- enumerations. The map DATA is passed in by the caller; no IO.
-- G5: every *_test.lua must yield >=1 passing engine test.
local repo_map = require("repo_map.crate")
local t = fkst.test

local function codex_map()
  return {
    exec = "codex-rs/exec",
    mcp = "codex-mcp",
    tui = "codex-rs/tui",
    default = "codex-rs",
  }
end

return {
  test_resolve_known_area = function()
    t.eq(repo_map.resolve(codex_map(), "exec"), "codex-rs/exec")
    t.eq(repo_map.resolve(codex_map(), "mcp"), "codex-mcp")
  end,

  test_resolve_is_case_insensitive = function()
    t.eq(repo_map.resolve(codex_map(), "Exec"), "codex-rs/exec")
    t.eq(repo_map.resolve(codex_map(), "TUI"), "codex-rs/tui")
  end,

  test_resolve_unknown_area_falls_back_to_default = function()
    t.eq(repo_map.resolve(codex_map(), "sandbox"), "codex-rs") -- default catch-all
  end,

  test_resolve_no_default_returns_nil = function()
    local map = { exec = "codex-rs/exec" }
    t.is_nil(repo_map.resolve(map, "sandbox"))
    t.is_nil(repo_map.resolve("not a table", "exec"))
  end,

  test_has_area_ignores_default = function()
    t.eq(repo_map.has_area(codex_map(), "exec"), true)
    t.eq(repo_map.has_area(codex_map(), "ExEc"), true)
    t.eq(repo_map.has_area(codex_map(), "sandbox"), false) -- default is not an area
    t.eq(repo_map.has_area(codex_map(), "default"), false)
  end,

  test_resolve_labels_picks_first_known = function()
    -- "app" + "browser" are unknown areas; "exec" is the first that maps.
    local hit = repo_map.resolve_labels(codex_map(), { "app", "browser", "exec", "mcp" })
    t.eq(hit.area, "exec")
    t.eq(hit.crate, "codex-rs/exec")
  end,

  test_resolve_labels_none_known_is_nil = function()
    t.is_nil(repo_map.resolve_labels(codex_map(), { "app", "browser" }))
  end,

  test_areas_and_crates_enumerate = function()
    local areas = repo_map.areas(codex_map())
    -- sorted, excludes `default`
    t.eq(#areas, 3)
    t.eq(areas[1], "exec")
    t.eq(areas[2], "mcp")
    t.eq(areas[3], "tui")
    local crates = repo_map.crates(codex_map())
    -- sorted + de-duplicated, includes the default crate path
    t.eq(#crates, 4)
    t.eq(crates[1], "codex-mcp")
  end,
}
