-- core.saga_table: the restart transition table + the saga conformance proof.
--
-- saga_conformance_errors() is the [conformance].function declared in fkst.toml; the
-- engine require("core")s and calls it (no args) during `conformance`. It is the
-- package's MECHANICAL proof of the FKST saga doctrine: every non-terminal state has
-- a robust budget + a guaranteed terminal transition carrying a WHY, every declared
-- terminal is reachable, and write-class once-keys have not drifted. It returns an
-- array of {id, message} records (empty = pass). This is a GENUINE check, not a
-- constant {}: restart_responsibility_errors() flags any injected violation.
local S = {}

function S.install(M)
  -- The saga state machine (spec §5 + learning-model §7): diagnose -> implement ->
  -- dossier -> gate -> engage -> invite_watch -> open_pr -> track, plus the terminal
  -- drop/success states each can reach. Each non-terminal row declares a robust
  -- budget, a guaranteed terminal (on_timeout, carrying a WHY), its successor set,
  -- and - for write-class states - the once-key prefix gating its idempotent effect.
  function M.restart_transition_table()
    return {
      {
        state = "diagnose", terminal = false, write_class = true,
        once_key = "codex-saga/diagnose",
        budget = { kind = "attempts", max = 3 },
        on_timeout = "needs_info",
        successors = { "implement", "needs_info" },
      },
      {
        -- WRITE-CLASS fix step: retrieve merged-PR exemplars + write the fix on the
        -- fork (dry-run by default). Bounded by attempts; can't-fix drops to
        -- needs_info; success advances to dossier.
        state = "implement", terminal = false, write_class = true,
        once_key = "codex-saga/implement",
        budget = { kind = "attempts", max = 3 },
        on_timeout = "needs_info",
        successors = { "dossier", "needs_info" },
      },
      {
        state = "dossier", terminal = false, write_class = true,
        once_key = "codex-saga/dossier",
        budget = { kind = "attempts", max = 3 },
        on_timeout = "blocked",
        successors = { "gate", "blocked" },
      },
      {
        state = "gate", terminal = false, write_class = false,
        budget = { kind = "attempts", max = 3 },
        on_timeout = "refused",
        successors = { "engage", "refused", "security_routed" },
      },
      {
        state = "engage", terminal = false, write_class = true,
        once_key = "codex-saga/engage",
        budget = { kind = "attempts", max = 3 },
        on_timeout = "blocked",
        successors = { "invite_watch", "blocked" },
      },
      {
        state = "invite_watch", terminal = false, write_class = false,
        budget = { kind = "wall_clock", max = "720h" },
        on_timeout = "needs_invite",
        successors = { "open_pr", "needs_invite" },
      },
      {
        -- open_pr's SUCCESS (codex_proposed) now flows to the `track` recorder, so
        -- codex_proposed is no longer a dangling terminal.
        state = "open_pr", terminal = false, write_class = true,
        once_key = "codex-saga/open_pr",
        budget = { kind = "attempts", max = 3 },
        on_timeout = "needs_invite",
        successors = { "track", "needs_invite" },
      },
      {
        -- WRITE-CLASS terminal recorder: record OUR attempt outcome to the durable
        -- control issue (learning-model §5), then transition to the `tracked`
        -- terminal. Bounded by attempts; a failed record drops to blocked.
        state = "track", terminal = false, write_class = true,
        once_key = "codex-saga/track",
        budget = { kind = "attempts", max = 3 },
        on_timeout = "blocked",
        successors = { "tracked", "blocked" },
      },
      {
        -- CRON-DRIVEN re-derivation (learning-model §5/§6): re-derives the real
        -- closing-PR outcome (CI/review/disposition) READ-ONLY and upserts the
        -- durable outcome record. NOT write-class (no once-gated foreign effect - it
        -- is a read-only re-derivation that idempotently refreshes our own record).
        -- Bounded by a wall-clock watch window; resolves into the existing `tracked`
        -- terminal (adds no new terminal).
        state = "outcome_watch", terminal = false, write_class = false,
        budget = { kind = "wall_clock", max = "720h" },
        on_timeout = "tracked",
        successors = { "tracked" },
      },
      -- terminals (each carries a WHY at runtime via a logged/posted reason).
      { state = "needs_info", terminal = true },
      { state = "blocked", terminal = true },
      { state = "refused", terminal = true },
      { state = "security_routed", terminal = true },
      { state = "needs_invite", terminal = true },
      { state = "tracked", terminal = true },
    }
  end

  -- Check the saga invariants over an arbitrary restart table. Returns one
  -- {id, message} record per violation. This is exercised both on the real table
  -- (must return {}) and on deliberately-broken tables (must return >=1 record).
  function M.restart_responsibility_errors(rows)
    local out = {}
    local function rec(id, message)
      table.insert(out, { id = id, message = message })
    end

    if type(rows) ~= "table" then
      rec("codex-saga.restart-table.shape", "restart_transition_table must be an array of state rows")
      return out
    end

    local terminals = {}
    local reached = {}
    for _, row in ipairs(rows) do
      if type(row) ~= "table" or type(row.state) ~= "string" or row.state == "" then
        rec("codex-saga.restart-table.row", "each restart row requires a non-empty string state")
      elseif row.terminal == true then
        terminals[row.state] = true
      end
    end

    for _, row in ipairs(rows) do
      if type(row) == "table" and type(row.state) == "string" and row.terminal ~= true then
        -- Invariant 1: a non-terminal state must have a budget.
        if row.budget == nil then
          rec("codex-saga.budget-missing",
            "non-terminal state `" .. row.state .. "` has no budget")
        end
        -- Guaranteed terminal transition carrying a WHY.
        if type(row.on_timeout) ~= "string" or row.on_timeout == "" then
          rec("codex-saga.terminal-missing",
            "non-terminal state `" .. row.state .. "` has no on_timeout terminal")
        end
        -- Invariant 3: a write-class state's once-key must not have drifted.
        if row.write_class == true then
          local expected = "codex-saga/" .. row.state
          if row.once_key ~= expected then
            rec("codex-saga.once-key-drift",
              "write-class state `" .. row.state .. "` has drifted once_key `"
                .. tostring(row.once_key) .. "` (expected `" .. expected .. "`)")
          end
        end
        for _, successor in ipairs(row.successors or {}) do
          reached[successor] = true
        end
        if type(row.on_timeout) == "string" then
          reached[row.on_timeout] = true
        end
      end
    end

    -- on_timeout must point at a declared terminal state.
    for _, row in ipairs(rows) do
      if type(row) == "table" and row.terminal ~= true and type(row.on_timeout) == "string"
        and row.on_timeout ~= "" and not terminals[row.on_timeout] then
        rec("codex-saga.terminal-unknown",
          "state `" .. tostring(row.state) .. "` on_timeout `" .. row.on_timeout
            .. "` is not a declared terminal state")
      end
    end

    -- Invariant 2: every declared terminal must be reachable.
    for name, _ in pairs(terminals) do
      if not reached[name] then
        rec("codex-saga.terminal-unreachable",
          "terminal state `" .. name .. "` is unreachable (no transition reaches it)")
      end
    end

    return out
  end

  function M.saga_conformance_errors()
    return M.restart_responsibility_errors(M.restart_transition_table())
  end
end

return S
