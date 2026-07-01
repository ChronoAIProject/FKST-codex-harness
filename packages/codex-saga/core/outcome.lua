-- core.outcome: READ-ONLY re-derivation of the closing-PR outcome (learning-model
-- §5/§6 - the closed feedback loop). track records ci="pending"/disposition="proposed"
-- at proposal time; this module re-derives the REAL facts (CI status, review themes,
-- final disposition, engagement reaction) from GitHub so codex-learn/relearn has a
-- genuine signal. RE-DERIVATION IS READ-ONLY on the foreign plane (gh reads only);
-- the durable outcome UPSERT onto our control issue reuses core.egress (dry-run by
-- default). No foreign write ever happens here.
local S = {}

local GH = "gh"

-- The induced review themes we recognize (canonical, deduped). review_comment_themes
-- is a small set of tags, never the review bodies (payload discipline).
local THEME_VOCAB = {
  "test", "style", "lint", "naming", "performance", "docs", "scope", "security", "types", "refactor",
}

function S.install(M)
  -- gh pr list by head branch (READ). Returns the matching PR array via gh_read.
  function M.gh_pr_list_argv(repo, head, fields)
    return {
      argv = { GH, "pr", "list", "--repo", tostring(repo), "--head", tostring(head),
        "--state", "all", "--json", fields or "number,state,statusCheckRollup,reviews,comments" },
      timeout = 30,
    }
  end

  function M.extract_themes(text)
    local found = {}
    local seen = {}
    local lower = tostring(text or ""):lower()
    for _, theme in ipairs(THEME_VOCAB) do
      if lower:find(theme, 1, true) ~= nil and not seen[theme] then
        seen[theme] = true
        table.insert(found, theme)
      end
    end
    return found
  end

  -- PURE: derive the §5 outcome facts from a gh PR view. Fail-closed: an unknown
  -- state stays "proposed", an indeterminate CI stays "pending".
  function M.derive_pr_outcome(view)
    view = view or {}
    local state = tostring(view.state or ""):upper()
    local disposition = "proposed"
    if state == "MERGED" then
      disposition = "merged"
    elseif state == "CLOSED" then
      disposition = "closed"
    end

    local any, failed, all_success = false, false, true
    for _, check in ipairs(view.statusCheckRollup or {}) do
      any = true
      local concl = tostring((type(check) == "table" and (check.conclusion or check.state)) or ""):upper()
      if concl == "FAILURE" or concl == "ERROR" or concl == "CANCELLED" or concl == "TIMED_OUT" or concl == "FAIL" then
        failed = true
      elseif concl ~= "SUCCESS" and concl ~= "NEUTRAL" and concl ~= "SKIPPED" then
        all_success = false
      end
    end
    local ci = "pending"
    if failed then
      ci = "fail"
    elseif any and all_success then
      ci = "pass"
    end

    local themes, seen = {}, {}
    local function collect(items)
      for _, item in ipairs(items or {}) do
        for _, theme in ipairs(M.extract_themes(type(item) == "table" and item.body or "")) do
          if not seen[theme] then
            seen[theme] = true
            table.insert(themes, theme)
          end
        end
      end
    end
    collect(view.reviews)
    collect(view.comments)

    local reaction = "invited"
    if disposition == "merged" then
      reaction = "positive"
    elseif #(view.reviews or {}) > 0 then
      reaction = "reply"
    end

    return { ci = ci, review_comment_themes = themes, disposition = disposition, engagement_reaction = reaction }
  end

  -- Inherit the small stable §5 fields (area_labels, type, picked_score, exemplars,
  -- advocate verdict) from the PRIOR durable record so outcome_watch's re-derived
  -- FINAL line carries them too (not just the proposed line). Type-guarded so a
  -- json-decoded null sentinel degrades to nil. The cron candidate carries no labels,
  -- so the durable JSONL (track's proposed record, latest-wins) is the source.
  function M.prior_outcome_fields(prior, source_ref)
    local function str_or_nil(v) return (type(v) == "string") and v or nil end
    local function num_or_nil(v) return (type(v) == "number") and v or nil end
    local function arr_or_nil(v) return (type(v) == "table") and v or nil end
    prior = prior or {}
    return {
      source_ref = source_ref,
      area_labels = arr_or_nil(prior.area_labels),
      type = str_or_nil(prior.type),
      picked_score = num_or_nil(prior.picked_score),
      exemplars_used = arr_or_nil(prior.exemplars_used),
      advocate_verdict = str_or_nil(prior.advocate_verdict),
      advocate_reason = str_or_nil(prior.advocate_reason),
    }
  end

  -- Merge the re-derived facts onto a base §5 outcome record (the one track wrote).
  function M.merge_outcome_facts(outcome, derived)
    outcome = outcome or {}
    derived = derived or {}
    for _, key in ipairs({ "ci", "review_comment_themes", "disposition", "engagement_reaction" }) do
      if derived[key] ~= nil then
        outcome[key] = derived[key]
      end
    end
    return outcome
  end

  -- Scan the tracker for the proposed/tracked candidates we recorded an outcome for:
  -- bot-authored control issues carrying the control marker + original source_ref.
  -- READ-ONLY; fail-closed (an unreadable scan yields no candidates).
  function M.proposed_candidates(exec)
    local bot = M.bot_login()
    local list = M.gh_read(M.gh_issue_list_argv(M.tracker_repo(), M.state_label("engaged"), "number,body,author"), exec)
    if type(list) ~= "table" then
      return {}
    end
    local out = {}
    for _, issue in ipairs(list) do
      if type(issue) == "table" and M.bot_authored(issue, bot) then
        local dedup_key = M.control_dedup_from_body(issue.body)
        local source_ref = M.control_source_ref_from_body(issue.body)
        if dedup_key ~= nil and source_ref ~= nil then
          table.insert(out, { dedup_key = dedup_key, source_ref = source_ref, control_issue = tostring(issue.number) })
        end
      end
    end
    return out
  end

  -- Locate the candidate's closing PR (the deterministic fork->upstream branch) and
  -- re-derive its outcome. READ-ONLY. Returns the §5 facts, or nil when no PR exists
  -- yet (e.g. dry-run: no real PR was ever opened).
  function M.rederive_candidate_outcome(candidate, exec)
    local branch = "codex-saga/fix-" .. M.safe_segment(candidate.dedup_key)
    local fork_owner = (M.fork_repo():match("^(.-)/") or "fork")
    local head = fork_owner .. ":" .. branch
    local prs = M.gh_read(M.gh_pr_list_argv(M.contrib_target(), head), exec)
    if type(prs) ~= "table" then
      return nil
    end
    local view = prs[1]
    if type(view) ~= "table" then
      return nil
    end
    return M.derive_pr_outcome(view)
  end
end

return S
