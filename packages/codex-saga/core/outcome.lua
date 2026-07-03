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
  --
  -- Broadened reconcile (#12): scan by the STABLE `candidate` label across --state all
  -- (open AND closed), NOT only currently-`engaged`-labeled issues. The candidate label
  -- is present from adopt through terminal and is never removed, so engagement history
  -- archived/relabeled/closed through resets keeps its control issue + markers and is
  -- still recovered here. Recovery stays bounded to candidates with a real closing PR
  -- (rederive_candidate_outcome returns nil otherwise, and dry-run has none), so nothing
  -- is over-claimed - only candidates that actually reached upstream produce an outcome.
  function M.proposed_candidates(exec)
    local bot = M.bot_login()
    local list = M.gh_read(M.gh_issue_list_argv(M.tracker_repo(), M.candidate_label(),
      "number,body,author", "all", 1000), exec)
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

  -- codex-learn's RESOLVED (terminal, foldable) disposition set. `ignored` is a resolved
  -- negative outcome, alongside merged/closed - a candidate the loop carried upstream but
  -- that never earned an invite within the wait window.
  local RESOLVED_DISPOSITIONS = { merged = true, closed = true, ignored = true }
  function M.is_resolved_disposition(disposition)
    return type(disposition) == "string" and RESOLVED_DISPOSITIONS[disposition] == true
  end

  -- #16: emit a TERMINAL "ignored" outcome for an engaged candidate whose invite-wait
  -- window elapsed with NO maintainer invite (learning-model resolved set, aligned with
  -- the saga on_timeout="needs_invite" terminal). Inherits the small §5 fold fields from
  -- the prior durable record (if any) and appends the terminal record (disposition=
  -- "ignored", engagement_reaction="none", plus state="needs_invite"/reason for the
  -- scoreboard). This is a LOCAL durable append only; NO foreign write. Idempotent: skips
  -- once a resolved terminal outcome already exists for the candidate, so repeated cron
  -- ticks don't re-append. opts.path targets the durable JSONL (tests use
  -- FKST_LEARNING_OUTCOMES_PATH / an explicit path). control_issue is accepted for the
  -- caller's log context; the visible control-issue board mirror for needs_invite is a
  -- follow-up (needs a `codex-saga.progress.needs_invite` locale key).
  function M.record_invite_ignored(dedup_key, source_ref, control_issue, opts)
    local prior = M.latest_outcome_by_dedup(M.read_outcomes(opts))[dedup_key]
    if type(prior) == "table" and M.is_resolved_disposition(prior.disposition) then
      return nil
    end
    local outcome = M.build_outcome(M.prior_outcome_fields(prior, source_ref))
    outcome.engagement_reaction = "none"
    outcome.disposition = "ignored"
    outcome.state = "needs_invite"
    outcome.reason = "invite_wait_elapsed"
    M.append_outcome(dedup_key, outcome, opts)
    log.info(string.format(
      "codex-saga/invite: invite-wait elapsed with no invite -> disposition=ignored dedup_key=%s control_issue=%s",
      tostring(dedup_key), tostring(control_issue)))
    return outcome
  end

  -- Locate the candidate's closing PR (the deterministic fork->upstream branch) and
  -- re-derive its outcome. READ-ONLY. Returns the §5 facts, or nil when no PR exists yet
  -- (e.g. dry-run: no real PR was ever opened) OR the PR has not reached a TERMINAL
  -- disposition (an OPEN PR stays disposition="proposed" - still in flight, so keep
  -- watching rather than over-claiming it as closed). Only merged|closed is recovered.
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
    local derived = M.derive_pr_outcome(view)
    if not M.is_resolved_disposition(derived.disposition) then
      return nil
    end
    return derived
  end
end

return S
