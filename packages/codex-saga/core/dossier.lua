-- core.dossier: outward issue/comment + PR body builders.
--
-- These assemble the OUTWARD prose (spec §10 output contract) from locale strings
-- (t()) plus small saga control fields (root cause, score, labels) and a precedent
-- read back from the corpus. Marker sentinels are appended by CODE (core.markers),
-- never sourced from the locale catalog.
local S = {}

function S.install(M)
  function M.impact_line(payload)
    payload = payload or {}
    local parts = {}
    if payload.score ~= nil then
      table.insert(parts, "calibrated priority score " .. tostring(payload.score))
    end
    local labels = payload.labels or {}
    if #labels > 0 then
      table.insert(parts, "area " .. table.concat(labels, ", "))
    end
    if #parts == 0 then
      return "see linked issue"
    end
    return table.concat(parts, "; ")
  end

  function M.validation_line(payload)
    payload = payload or {}
    if M.is_nonempty_string(payload.validation) then
      return tostring(payload.validation)
    end
    if M.is_nonempty_string(payload.test_command) then
      return "`" .. tostring(payload.test_command) .. "`"
    end
    return t("codex-saga.engage.validation_default")
  end

  function M.fix_scope_line(payload)
    payload = payload or {}
    local root_cause = payload.root_cause
    if M.is_nonempty_string(root_cause) then
      return t("codex-saga.engage.fix_scope_with_root", { root_cause = tostring(root_cause) })
    end
    return t("codex-saga.engage.fix_scope_default")
  end

  -- A prepared fork branch is "live" (safe to render as a tree/compare LINK) ONLY when
  -- it was actually pushed: a named branch, NOT flagged simulated by the branch step
  -- (Agent E's `simulated` marker), and running under the real write posture. In
  -- dry-run the fork push never happens, so a branch is NEVER live - render it honestly
  -- as prepared-locally, never as a live link (#8; two-plane / dry-run discipline).
  function M.branch_is_live(payload)
    payload = payload or {}
    return M.is_nonempty_string(payload.demo_branch)
      and payload.simulated ~= true
      and M.write_mode() == "real"
  end

  -- Refuse-to-post precondition for the outward dossier (integrity gate #22a). The
  -- static template is a FALLBACK, not a default: unless the key artifacts are all
  -- present + VERIFIED - a truly-verified root cause (Agent A), a real validation plan
  -- (Agent E), and a LIVE pushed fork branch - engage REFUSES to post rather than emit
  -- unsubstantiated boilerplate. Returns (true) when postable, else (false, reason).
  function M.dossier_postable(payload)
    payload = payload or {}
    if payload.root_cause_verified ~= true then
      return false, t("codex-saga.engage.refuse_unverified")
    end
    -- Real validation artifact: require the actual test COMMAND codex reported running
    -- (payload.test_command). A non-empty `validation` string is NOT sufficient - the
    -- honest no-test sentinel ("no test command reported by codex") and the dry-run
    -- "not run (simulated)" note are both non-empty yet mean nothing was validated.
    if not M.is_nonempty_string(payload.test_command) then
      return false, t("codex-saga.engage.refuse_unverified")
    end
    if not M.branch_is_live(payload) then
      return false, t("codex-saga.engage.refuse_unverified")
    end
    return true
  end

  -- The dossier comment posted on the openai/codex candidate issue, COMPOSED via
  -- retrieval-conditioned engagement learning (learning-model §4): the exemplar order
  -- prefers relearn's credit-weighted re-ranked bank (core.engagement), and the comment
  -- cites how many nearest SUCCESSFUL engagement threads (retrieved via precedent.tfidf
  -- over corpus_engagement) it imitates - REFS carried upstream for credit assignment,
  -- never the threads themselves (payload discipline). The asserted reproduction /
  -- root-cause claims are gated on the VERIFIED diagnose facts (#2), never on styleguide
  -- text. ALWAYS ends with the mandatory AI-disclosure line (spec §10 gate7).
  function M.engage_body(entity, payload)
    payload = payload or {}
    local root_cause = payload.root_cause
    if not M.is_nonempty_string(root_cause) then
      root_cause = "(diagnosis pending)"
    end
    local precedent = M.select_precedent(M.read_corpus(), payload.labels or {})

    -- Consume the induced engagement rules + the retrieved engagement exemplars
    -- (use the refs dossier already retrieved + carried, else retrieve fresh), then
    -- PREFER relearn's re-ranked exemplar bank order (#17).
    local rules = M.read_engagement_styleguide()
    local exemplar_refs = payload.engagement_exemplars
    if exemplar_refs == nil then
      exemplar_refs = M.engagement_exemplar_refs(M.retrieve_engagement_exemplars(M.engagement_target(payload, rules)))
    end
    exemplar_refs = M.rerank_refs_by_bank(exemplar_refs, M.read_engagement_exemplar_bank())

    local lines = { t("codex-saga.engage.heading"), "" }
    table.insert(lines, t("codex-saga.engage.intro"))
    table.insert(lines, "")

    table.insert(lines, t("codex-saga.engage.breakdown_heading"))
    -- Asserted reproduction claim: ONLY when the payload's `reproduced` flag is truly
    -- verified (Agent A). Real reproduction is not implemented yet, so by default this
    -- line is NOT rendered - we never claim a reproduction we did not perform (#2).
    if payload.reproduced == true then
      table.insert(lines, "- " .. t("codex-saga.engage.repro_line"))
    end
    -- Root cause: assert only when VERIFIED; otherwise HEDGE ("Suspected root cause"),
    -- so an unverified diagnosis is never stated as fact (#2).
    local rc_label = payload.root_cause_verified == true
      and t("codex-saga.engage.root_cause_label")
      or t("codex-saga.engage.root_cause_label_suspected")
    table.insert(lines, "- " .. rc_label .. ": " .. tostring(root_cause))
    table.insert(lines, "- " .. t("codex-saga.engage.impact_label") .. ": " .. M.impact_line(payload))
    table.insert(lines, "")

    table.insert(lines, t("codex-saga.engage.approach_heading"))
    table.insert(lines, "- " .. M.fix_scope_line(payload))
    table.insert(lines, "- " .. t("codex-saga.engage.validation_label") .. ": " .. M.validation_line(payload))
    if M.is_nonempty_string(payload.demo_branch) then
      local branch = tostring(payload.demo_branch)
      if M.branch_is_live(payload) then
        -- A real pushed branch: render the tree + cross-fork compare LINK section.
        table.insert(lines, "- " .. t("codex-saga.engage.branch_label") .. ": ["
          .. branch .. "](" .. M.branch_url(branch) .. ") · ["
          .. t("codex-saga.engage.branch_compare") .. "](" .. M.compare_url(branch) .. ")")
      else
        -- Not pushed (dry-run / simulated): name it honestly, no live link (#8).
        table.insert(lines, "- " .. t("codex-saga.engage.branch_label") .. ": `"
          .. branch .. "` " .. t("codex-saga.engage.branch_simulated_note"))
      end
    end
    table.insert(lines, "- " .. t("codex-saga.engage.invite_policy"))
    table.insert(lines, "")

    if precedent ~= nil and precedent.number ~= nil then
      table.insert(lines, t("codex-saga.engage.precedent_label") .. ": #"
        .. tostring(precedent.number) .. " " .. tostring(precedent.title or ""))
    else
      table.insert(lines, t("codex-saga.engage.precedent_label") .. ": " .. t("codex-saga.engage.precedent_none"))
    end
    table.insert(lines, "")
    if #exemplar_refs > 0 then
      table.insert(lines, t("codex-saga.engage.learning_heading"))
      table.insert(lines, "- " .. t("codex-saga.engage.modeled_on", { count = tostring(#exemplar_refs) }))
      table.insert(lines, "- " .. t("codex-saga.engage.learning_moves"))
      table.insert(lines, "")
    end
    table.insert(lines, t("codex-saga.engage.disclose_ai"))
    return table.concat(lines, "\n")
  end

  -- Control issue title/body on the saga tracker. The body carries the control +
  -- initial state markers (CODE), which are the durable saga truth.
  function M.control_title(dedup_key)
    return t("codex-saga.control.title", { dedup_key = tostring(dedup_key) })
  end

  -- Human display of the upstream candidate: "openai/codex#16335" (never the tracker).
  function M.upstream_display(source_ref)
    local parsed = M.parse_entity_ref(source_ref)
    if parsed ~= nil then
      return parsed.repo .. "#" .. parsed.number
    end
    if type(source_ref) == "table" and type(source_ref.ref) == "string" then
      return source_ref.ref
    end
    return "(unknown)"
  end

  -- ---- board link builders (pure URL strings; board detail only) ---------------
  function M.issue_url(source_ref)
    local parsed = M.parse_entity_ref(source_ref)
    if parsed == nil then
      return nil
    end
    return "https://github.com/" .. parsed.repo .. "/issues/" .. parsed.number
  end

  -- The fix branch on the fork (owned plane).
  function M.branch_url(branch)
    return "https://github.com/" .. M.fork_repo() .. "/tree/" .. tostring(branch)
  end

  -- Cross-fork compare on the upstream: upstream main vs the fork fix branch - the
  -- exact diff a future PR would carry.
  function M.compare_url(branch)
    local owner, name = M.fork_repo():match("^(.-)/(.+)$")
    if owner == nil then
      return M.branch_url(branch)
    end
    return "https://github.com/" .. M.contrib_target() .. "/compare/main..."
      .. owner .. ":" .. name .. ":" .. tostring(branch)
  end

  -- The first https URL a gh write printed (issue/comment/PR URL), from the egress
  -- intent's captured stdout (real mode only; nil in dry-run).
  function M.url_from_intent(intent)
    if type(intent) ~= "table" or not M.is_nonempty_string(intent.stdout) then
      return nil
    end
    return intent.stdout:match("https://%S+")
  end

  -- The control issue body: a rich, human-readable "fkst ai log" (visible arguments in a
  -- markdown block, like the reference shorts loop) PLUS the hidden HTML-comment markers
  -- (the durable saga truth GitHub does not render). ctx carries the small adopt-time
  -- arguments {score, area_labels, type} (nil-safe); root cause + later facts arrive as
  -- comments. Marker sentinels are CODE (core.markers), never locale content.
  function M.control_body(dedup_key, state, source_ref, ctx)
    ctx = ctx or {}
    local upstream = M.upstream_display(source_ref)
    -- Link the upstream issue when the ref parses (board navigability).
    local url = M.issue_url(source_ref)
    local upstream_line = url ~= nil and ("[" .. upstream .. "](" .. url .. ")") or upstream
    local lines = {
      t("codex-saga.control.heading"),
      "",
      t("codex-saga.control.upstream_label") .. ": " .. upstream_line,
      "",
      t("codex-saga.control.why_heading"),
      "",
    }
    if ctx.score ~= nil then
      lines[#lines + 1] = "- **" .. t("codex-saga.control.score_label") .. "**: "
        .. tostring(ctx.score) .. " · " .. t("codex-saga.control.score_note")
    end
    local labels = ctx.area_labels or {}
    if #labels > 0 then
      lines[#lines + 1] = "- **" .. t("codex-saga.control.area_label") .. "**: " .. table.concat(labels, ", ")
    end
    if M.is_nonempty_string(ctx.type) then
      lines[#lines + 1] = "- **" .. t("codex-saga.control.type_label") .. "**: " .. tostring(ctx.type)
    end
    lines[#lines + 1] = "- **" .. t("codex-saga.control.detected_label") .. "**: " .. t("codex-saga.control.detected_by")
    lines[#lines + 1] = ""
    -- The run plan: how each numbered phase will be executed for this candidate. Static
    -- (locale-driven); the live position is the flipping codex-saga:<n>/6 label and the
    -- per-stage progress comments below.
    lines[#lines + 1] = t("codex-saga.control.plan_heading")
    lines[#lines + 1] = ""
    for i = 1, 6 do
      lines[#lines + 1] = t("codex-saga.plan." .. tostring(i))
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = t("codex-saga.control.pipeline_note")
    lines[#lines + 1] = ""
    lines[#lines + 1] = "---"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "🔗 source: " .. upstream .. " · dedup: `" .. tostring(dedup_key) .. "`"
    lines[#lines + 1] = "🤖 " .. t("codex-saga.control.generated_by")
    lines[#lines + 1] = ""
    lines[#lines + 1] = t("codex-saga.control.auto_loop_tag")
    lines[#lines + 1] = ""
    -- Hidden durable markers (control identity, state mirror, original-candidate pointer).
    lines[#lines + 1] = M.control_marker(dedup_key)
    lines[#lines + 1] = M.state_marker(dedup_key, state or "diagnosing")
    lines[#lines + 1] = M.source_marker(dedup_key, source_ref)
    return table.concat(lines, "\n")
  end

  -- PR body (only built after a recorded invitation). The CLA acknowledgement is a
  -- separate comment (cla_comment()).
  function M.pr_body(payload)
    payload = payload or {}
    local root_cause = payload.root_cause
    if not M.is_nonempty_string(root_cause) then
      root_cause = "(see linked issue)"
    end
    -- Hedge the label unless the root cause is VERIFIED (#2 integrity consistency).
    local rc_label = payload.root_cause_verified == true
      and t("codex-saga.engage.root_cause_label")
      or t("codex-saga.engage.root_cause_label_suspected")
    local lines = {
      t("codex-saga.pr.heading"),
      "",
      t("codex-saga.pr.linked"),
      "",
      rc_label .. ": " .. tostring(root_cause),
      "",
      t("codex-saga.engage.disclose_ai"),
    }
    return table.concat(lines, "\n")
  end

  function M.cla_comment()
    return t("codex-saga.pr.cla")
  end
end

return S
