-- codex-saga OUTWARD-comment integrity tests (Agent F; DRY-RUN, no network).
-- Cover the P0 integrity surface: never assert an unverified reproduction/root cause
-- (#2), render a prepared branch honestly when it was not pushed (#8), consume the
-- relearn re-ranked exemplar bank (#17), the refuse-to-post artifact gate (#22a), and
-- the comment-diversity gate (#3). `tk` is the test kit; global `t` is the i18n fn.
local core = require("core")
local tk = fkst.test

local function candidate_ref()
  return { kind = "external", ref = "openai/codex#issues/1234" }
end

return {
  -- ---- #2: never assert an unverified reproduction / root cause ----------------
  test_engage_body_omits_repro_claim_when_not_verified = function()
    local body = core.engage_body(candidate_ref(),
      { root_cause = "src/exec/mod.rs:88", labels = { "bug" } })
    -- the asserted reproduction claim is NOT present without a verified `reproduced`.
    tk.eq(body:find(t("codex-saga.engage.repro_line"), 1, true), nil)
    -- the root cause is HEDGED, never stated as fact.
    tk.is_true(body:find("Suspected root cause", 1, true) ~= nil)
    tk.eq(body:find("- Root cause:", 1, true), nil)
    -- still carries the file:line + the mandatory AI disclosure.
    tk.is_true(body:find("src/exec/mod.rs:88", 1, true) ~= nil)
    tk.is_true(body:find(t("codex-saga.engage.disclose_ai"), 1, true) ~= nil)
  end,

  test_engage_body_asserts_only_when_verified = function()
    local body = core.engage_body(candidate_ref(),
      { root_cause = "src/exec/mod.rs:88", labels = { "bug" },
        reproduced = true, root_cause_verified = true })
    tk.is_true(body:find(t("codex-saga.engage.repro_line"), 1, true) ~= nil)
    tk.is_true(body:find("- Root cause:", 1, true) ~= nil)
    tk.eq(body:find("Suspected root cause", 1, true), nil)
  end,

  -- ---- #7: validation line uses REAL data, default only when absent ------------
  test_validation_line_prefers_real_data = function()
    tk.eq(core.validation_line({ validation = "ran cargo test -p codex-exec" }),
      "ran cargo test -p codex-exec")
    tk.eq(core.validation_line({ test_command = "just test" }), "`just test`")
    tk.eq(core.validation_line({}), t("codex-saga.engage.validation_default"))
  end,

  -- ---- #8: a not-pushed fork branch is rendered honestly, never as a live link -
  test_engage_body_branch_is_honest_when_not_pushed = function()
    local body = core.engage_body(candidate_ref(),
      { root_cause = "x", labels = { "bug" }, demo_branch = "codex-saga/fix-9" })
    tk.is_true(body:find("codex-saga/fix-9", 1, true) ~= nil)
    tk.is_true(body:find(t("codex-saga.engage.branch_simulated_note"), 1, true) ~= nil)
    -- dry-run never renders a live fork tree/compare link.
    tk.eq(body:find("/tree/", 1, true), nil)
    tk.eq(body:find("/compare/", 1, true), nil)
  end,

  test_branch_is_live_is_false_in_dry_run = function()
    tk.eq(core.branch_is_live({ demo_branch = "b", simulated = false }), false)
    tk.eq(core.branch_is_live({ demo_branch = "b" }), false)
    tk.eq(core.branch_is_live({}), false)
  end,

  -- ---- #22a: refuse-to-post unless the key artifacts are verified --------------
  test_dossier_postable_refuses_unverified = function()
    local ok1, reason1 = core.dossier_postable({})
    tk.eq(ok1, false)
    tk.eq(reason1, t("codex-saga.engage.refuse_unverified"))
    tk.eq(core.dossier_postable({ root_cause_verified = true }), false) -- no validation
    -- P2: a non-empty but non-REAL validation (the no-test sentinel) is NOT sufficient;
    -- postability requires the actual test COMMAND codex reported running.
    tk.eq(core.dossier_postable({ root_cause_verified = true,
      validation = "no test command reported by codex", demo_branch = "b" }), false)
    tk.eq(core.dossier_postable({ root_cause_verified = true, test_command = "cargo test" }), false) -- branch not live
    -- fully-populated but dry-run: still refuses, because the branch is not pushed.
    tk.eq(core.dossier_postable({ root_cause_verified = true, test_command = "cargo test",
      demo_branch = "b", simulated = false }), false)
  end,

  -- The engage department REFUSES the outward post for an unverified payload (no real test
  -- command / no live pushed branch) and is TERMINAL: it does NOT advance the saga (no
  -- codex_engaged), so invite_watch/open_pr never process a candidate the bot never
  -- publicly engaged (integrated Codex review P1). Refusal is recorded locally with ZERO
  -- gh/git write.
  test_engage_refuses_unverified_and_is_terminal = function()
    local result = tk.run_department("departments/engage/main.lua", {
      queue = "codex_cleared",
      payload = {
        schema = "codex-saga.cleared.v1",
        dedup_key = "codex-triage:candidate:openai/codex#1234",
        source_ref = candidate_ref(),
        root_cause = "src/exec/mod.rs:88",
        labels = { "bug" },
        score = 0.73,
      },
    })
    tk.eq(result.exit_code, 0)
    local raised = 0
    for _, e in ipairs(result.raises or {}) do
      if tostring(e.queue):find("codex_engaged", 1, true) ~= nil then raised = raised + 1 end
    end
    tk.eq(raised, 0) -- TERMINAL: no codex_engaged raised on refusal
    tk.eq(#tk.command_calls(), 0) -- refuse-to-post performs NO gh/git write
  end,

  -- ---- #17: consume relearn's re-ranked "## Exemplar bank" ---------------------
  test_parse_styleguide_exemplar_bank = function()
    local text = table.concat({
      "# Engagement styleguide",
      "- Lead with the reproduction",
      "",
      "## Exemplar bank (re-ranked)",
      "1. openai/codex#2417",
      "2. openai/codex#87",
      "",
      "## Notes",
      "3. not-a-bank-ref",
    }, "\n")
    local bank = core.parse_styleguide_exemplar_bank(text)
    tk.eq(#bank, 2)
    tk.eq(bank[1], "openai/codex#2417")
    tk.eq(bank[2], "openai/codex#87")
    -- reading via the injected-text seam yields the same bank.
    tk.eq(#core.read_engagement_exemplar_bank({ text = text }), 2)
  end,

  test_rerank_refs_by_bank_prefers_bank_order = function()
    tk.eq(table.concat(core.rerank_refs_by_bank({ "a", "b", "c" }, { "c", "a" }), ","),
      "c,a,b")
    -- empty bank -> unchanged (fail-soft before relearn runs).
    tk.eq(table.concat(core.rerank_refs_by_bank({ "a", "b" }, {}), ","), "a,b")
    -- bank refs not present in the retrieved set are ignored (no injection).
    tk.eq(table.concat(core.rerank_refs_by_bank({ "a", "b" }, { "z", "b" }), ","), "b,a")
  end,

  -- ---- #3: comment-diversity gate ---------------------------------------------
  test_body_similarity_and_duplicate_detection = function()
    local body = core.engage_body(candidate_ref(), { root_cause = "x", labels = { "bug" } })
    tk.eq(core.body_similarity(body, body), 1)
    tk.is_true(core.is_boilerplate_duplicate(body, { body }))
    tk.eq(core.is_boilerplate_duplicate(body, { "utterly unrelated tokens alpha bravo" }), false)
    -- empty recents -> never a duplicate.
    tk.eq(core.is_boilerplate_duplicate(body, {}), false)
    -- diversity_ok mirrors the refusal reason.
    local ok, reason = core.diversity_ok(body, { body })
    tk.eq(ok, false)
    tk.eq(reason, t("codex-saga.engage.refuse_duplicate"))
    tk.is_true(core.diversity_ok(body, {}))
  end,

  test_body_fingerprint_is_single_line = function()
    local fp = core.body_fingerprint("Alpha beta\nGamma alpha")
    tk.eq(fp:find("\n", 1, true), nil)
    -- unique, lowercased, sorted tokens.
    tk.eq(fp, "alpha beta gamma")
  end,

  test_engage_body_ring_round_trips = function()
    local path = (os.getenv("FKST_RUNTIME_ROOT") or ".") .. "/saga-engage-ring-test.ring"
    tk.eq(#core.recent_engage_bodies(path), 0) -- absent -> empty
    core.record_engage_body("alpha beta gamma", path)
    local recent = core.recent_engage_bodies(path)
    tk.eq(#recent, 1)
    tk.eq(recent[1], "alpha beta gamma")
    -- a near-identical later body is caught against the ring.
    tk.is_true(core.is_boilerplate_duplicate("alpha beta gamma delta", recent, 0.5))
  end,
}
