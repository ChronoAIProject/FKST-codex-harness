-- core.track: the terminal recorder's outcome schema + durable recording.
--
-- track is the learning loop's "record" arm (docs/learning-model.md §5/§6/§7): per
-- attempt it produces the outcome record and records it to the DURABLE saga mirror -
-- the control issue on this harness repo's tracker (the architecture's durable
-- GitHub-mirror fact source, spec §6). codex-learn re-derives the banks/weights from
-- these outcomes (§3). The record is small (refs + scalars), never diffs/bodies.
--
-- Posture: recording to GitHub is an egress, so it is DRY-RUN BY DEFAULT (no network
-- unless FKST_GITHUB_WRITE=1) - reusing core.egress's marker-gated write path.
local S = {}

function S.install(M)
  -- The small learning fields threaded down the chain so credit assignment (which
  -- exemplars / which advocate verdict led to which outcome) survives to track.
  -- Carried as refs/scalars per the payload-discipline (NEVER diffs or bodies).
  -- `labels` is threaded too so the terminal recorder can derive the §5 area_labels +
  -- type for the rubric re-fit fold (codex-learn), not just calibration.
  -- `demo_branch`/`test_command`/`validation` (implement/dossier -> engage -> open_pr) and
  -- `root_cause_verified`/`reproduced` (diagnose -> engage) are SMALL scalars (a branch
  -- name, a command string, a short plan line, booleans) - never diffs/bodies - so they
  -- ride the same carry as the rest of the credit-assignment metadata. Without them the
  -- gate DROPS these fields (e.g. the "Prepared fork branch" line went unreachable), so
  -- add them here to auto-propagate the chain via merge_learning.
  -- `simulated` (implement's dry-run/failed-push marker) rides too: without it the gate
  -- drops the truth that a branch was NOT pushed, so engage could render a live link for
  -- a nonexistent branch in real mode (dossier's branch_is_live check needs it).
  local LEARNING_KEYS = { "picked_score", "exemplars_used", "advocate_verdict", "advocate_reason", "engagement_exemplars", "labels", "consensus_angles", "deliberation_count", "approach", "consensus_rounds", "converge_mode", "demo_branch", "test_command", "validation", "root_cause_verified", "reproduced", "simulated" }

  function M.learning_keys()
    return LEARNING_KEYS
  end

  -- Copy the learning fields from an incoming payload onto an outgoing raise payload
  -- (only when not already set). Departments call this to thread credit-assignment
  -- metadata implement..gate -> track without re-deriving it.
  function M.merge_learning(out, payload)
    payload = payload or {}
    for _, key in ipairs(LEARNING_KEYS) do
      if out[key] == nil and payload[key] ~= nil then
        out[key] = payload[key]
      end
    end
    return out
  end

  -- Classify the §5 `type` from the candidate labels (bug|regression|enhancement|
  -- other), regression taking precedence. Small scalar derivable from the labels.
  function M.classify_type(labels)
    local has = {}
    for _, label in ipairs(labels or {}) do
      has[tostring(label):lower()] = true
    end
    if has["regression"] then return "regression" end
    if has["bug"] then return "bug" end
    if has["enhancement"] then return "enhancement" end
    return "other"
  end

  -- Build the outcome record (docs/learning-model.md §5 schema). area_labels + type
  -- are small scalars folded by codex-learn into the rubric re-fit + styleguides; they
  -- are derived from the threaded candidate labels (or carried explicitly when
  -- inherited). At codex_proposed time the PR has been opened (so we were invited);
  -- the post-merge facts (ci, final disposition, review themes) are re-derived later
  -- from GitHub, so they record their not-yet-known sentinel here.
  function M.build_outcome(payload)
    payload = payload or {}
    local labels = payload.labels or payload.area_labels or {}
    return {
      source_ref = payload.source_ref,
      picked_score = payload.picked_score or payload.score,
      area_labels = payload.area_labels or labels,
      type = payload.type or M.classify_type(labels),
      exemplars_used = payload.exemplars_used or {},
      engagement_reaction = payload.engagement_reaction or "invited",
      ci = payload.ci or "pending",
      review_comment_themes = payload.review_comment_themes or {},
      disposition = payload.disposition or "proposed",
      advocate_verdict = payload.advocate_verdict or "unknown",
      advocate_reason = payload.advocate_reason,
      -- Deliberation signals threaded gate -> track (learning-model §7): the per-angle
      -- verdict map + the count of judgments the gate weighed, so a PASS carries its
      -- deliberation into the durable record + control-issue comment.
      consensus_angles = payload.consensus_angles,
      deliberation_count = payload.deliberation_count,
      -- Iterative-deliberation signals (rounds run + how convergence was reached).
      consensus_rounds = payload.consensus_rounds,
      converge_mode = payload.converge_mode,
      -- Invite-recovery rehydration fields (integrity): carry the diagnose-time verification
      -- + branch-liveness into EVERY durable record. `load_engaged_verification` is
      -- latest-wins by dedup_key, so once this proposed/tracked record supersedes the
      -- engaged-verification row, a later invite-recovery tick must still find these facts
      -- here - else open_pr's fail-closed preflight would wrongly refuse a genuinely
      -- verified, invited candidate (Codex review). Carried on the payload via LEARNING_KEYS.
      root_cause_verified = payload.root_cause_verified,
      demo_branch = payload.demo_branch,
      simulated = payload.simulated,
    }
  end

  -- Render the per-angle deliberation map to a stable "angle=verdict" string (keys
  -- SORTED so the control-issue comment line is deterministic). Empty/nil -> "(none)".
  function M.render_consensus_angles(angles)
    if type(angles) ~= "table" then
      return "(none)"
    end
    local keys = {}
    for key in pairs(angles) do
      keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    if #keys == 0 then
      return "(none)"
    end
    local parts = {}
    for _, key in ipairs(keys) do
      parts[#parts + 1] = key .. "=" .. tostring(angles[key])
    end
    return table.concat(parts, ", ")
  end

  -- Render the outcome record to a stable text block for the control-issue comment.
  -- (json has no encode; the block is deterministic key: value lines + an outcome
  -- marker appended by core.egress, so codex-learn can re-parse it from GitHub.)
  function M.render_outcome(outcome)
    outcome = outcome or {}
    local ref = "(none)"
    if type(outcome.source_ref) == "table" and type(outcome.source_ref.ref) == "string" then
      ref = outcome.source_ref.ref
    end
    local lines = {
      t("codex-saga.track.heading"),
      "",
      "source_ref: " .. ref,
      "picked_score: " .. tostring(outcome.picked_score),
      "area_labels: " .. table.concat(outcome.area_labels or {}, ", "),
      "type: " .. tostring(outcome.type),
      "exemplars_used: " .. table.concat(outcome.exemplars_used or {}, ", "),
      "engagement_reaction: " .. tostring(outcome.engagement_reaction),
      "ci: " .. tostring(outcome.ci),
      "review_comment_themes: " .. table.concat(outcome.review_comment_themes or {}, ", "),
      "disposition: " .. tostring(outcome.disposition),
      "advocate_verdict: " .. tostring(outcome.advocate_verdict),
      "advocate_reason: " .. tostring(outcome.advocate_reason or ""),
      "consensus_angles: " .. M.render_consensus_angles(outcome.consensus_angles),
      "deliberation_count: " .. tostring(outcome.deliberation_count or 0),
      "consensus_rounds: " .. tostring(outcome.consensus_rounds or 1),
      "converge_mode: " .. tostring(outcome.converge_mode or "unanimous"),
    }
    return table.concat(lines, "\n")
  end

  -- Record the attempt outcome durably as a bot-authored comment on the saga control
  -- issue (dry-run by default; the outcome marker gates the genuinely-once post). The
  -- returned intent carries the rendered record; in dry-run NO network call happens.
  function M.record_outcome(dedup_key, outcome, control_issue)
    -- Resolve the control issue locator once (real mode only; dry-run never reads GitHub,
    -- so egress_write returns before the closures). If it cannot be located, fail closed
    -- (skip) rather than commenting on issue "" (mirrors core.progress.record_transition).
    if control_issue == nil and M.write_mode() == "real" then
      control_issue = M.control_issue_number(dedup_key)
      if control_issue == nil then
        log.warn("codex-saga/track: no control issue located for " .. tostring(dedup_key)
          .. "; skipping the visible outcome mirror (durable append already recorded)")
        return { mode = "real", op = "track-outcome", skipped = true }
      end
    end
    return M.egress_write({
      op = "track-outcome",
      repo = M.tracker_repo(),
      dedup_key = dedup_key,
      body = M.render_outcome(outcome),
      marker = M.outcome_marker(dedup_key),
      argv_builder = function(path)
        return M.gh_issue_comment_argv(M.tracker_repo(), tostring(control_issue), path)
      end,
      marker_present = function()
        -- Trust the outcome marker ONLY on a bot-authored comment on the control issue.
        local bot = M.bot_login()
        local view = M.gh_read(M.gh_issue_view_argv(M.tracker_repo(), tostring(control_issue), "comments"))
        if type(view) ~= "table" then
          return false
        end
        local marker = M.outcome_marker(dedup_key)
        for _, comment in ipairs(view.comments or {}) do
          if M.trusted_marker(comment, marker, bot) then
            return true
          end
        end
        return false
      end,
    })
  end
end

return S
