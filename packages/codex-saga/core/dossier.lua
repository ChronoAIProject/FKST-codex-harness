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

  -- The dossier comment posted on the openai/codex candidate issue, COMPOSED via
  -- retrieval-conditioned engagement learning (learning-model §4): the section set is
  -- driven by the induced engagement_styleguide rules (core.engagement), and the
  -- comment cites how many nearest SUCCESSFUL engagement threads (retrieved via
  -- precedent.tfidf over corpus_engagement) it imitates - REFS carried upstream for
  -- credit assignment, never the threads themselves (payload discipline). ALWAYS ends
  -- with the mandatory AI-disclosure line (spec §10 gate7).
  function M.engage_body(entity, payload)
    payload = payload or {}
    local root_cause = payload.root_cause
    if not M.is_nonempty_string(root_cause) then
      root_cause = "(diagnosis pending)"
    end
    local precedent = M.select_precedent(M.read_corpus(), payload.labels or {})

    -- Consume the induced engagement rules + the retrieved engagement exemplars
    -- (use the refs dossier already retrieved + carried, else retrieve fresh).
    local rules = M.read_engagement_styleguide()
    local exemplar_refs = payload.engagement_exemplars
    if exemplar_refs == nil then
      exemplar_refs = M.engagement_exemplar_refs(M.retrieve_engagement_exemplars(M.engagement_target(payload, rules)))
    end

    local lines = { t("codex-saga.engage.heading"), "" }
    -- rule-driven: lead with the reproduction / cite the root cause (file:line).
    if M.styleguide_has(rules, "repro") or M.styleguide_has(rules, "root cause") then
      table.insert(lines, t("codex-saga.engage.root_cause_label") .. ": " .. tostring(root_cause))
      table.insert(lines, "")
    end
    table.insert(lines, t("codex-saga.engage.impact_label") .. ": " .. M.impact_line(payload))
    table.insert(lines, "")
    if precedent ~= nil and precedent.number ~= nil then
      table.insert(lines, t("codex-saga.engage.precedent_label") .. ": #"
        .. tostring(precedent.number) .. " " .. tostring(precedent.title or ""))
    else
      table.insert(lines, t("codex-saga.engage.precedent_label") .. ": " .. t("codex-saga.engage.precedent_none"))
    end
    table.insert(lines, "")
    -- rule-driven: offer to implement / ask the maintainer for direction.
    if M.styleguide_has(rules, "implement") or M.styleguide_has(rules, "direction") then
      table.insert(lines, t("codex-saga.engage.approach"))
      table.insert(lines, "")
    end
    -- retrieval-conditioned framing: imitate what worked on similar issues.
    if #exemplar_refs > 0 then
      table.insert(lines, t("codex-saga.engage.modeled_on", { count = tostring(#exemplar_refs) }))
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

  function M.control_body(dedup_key, state, source_ref)
    local lines = {
      t("codex-saga.control.body"),
      "",
      M.control_marker(dedup_key),
      M.state_marker(dedup_key, state or "engaged"),
      -- A tiny pointer back to the ORIGINAL openai/codex candidate (ref only); the
      -- invite path re-derives the original source_ref from this, never the tracker.
      M.source_marker(dedup_key, source_ref),
    }
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
    local lines = {
      t("codex-saga.pr.heading"),
      "",
      t("codex-saga.pr.linked"),
      "",
      t("codex-saga.engage.root_cause_label") .. ": " .. tostring(root_cause),
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
