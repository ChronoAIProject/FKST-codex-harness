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
  local LEARNING_KEYS = { "picked_score", "exemplars_used", "advocate_verdict", "advocate_reason", "engagement_exemplars", "labels" }

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
    }
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
    }
    return table.concat(lines, "\n")
  end

  -- Record the attempt outcome durably as a bot-authored comment on the saga control
  -- issue (dry-run by default; the outcome marker gates the genuinely-once post). The
  -- returned intent carries the rendered record; in dry-run NO network call happens.
  function M.record_outcome(dedup_key, outcome, control_issue)
    return M.egress_write({
      op = "track-outcome",
      repo = M.tracker_repo(),
      dedup_key = dedup_key,
      body = M.render_outcome(outcome),
      marker = M.outcome_marker(dedup_key),
      argv_builder = function(path)
        return M.gh_issue_comment_argv(M.tracker_repo(), tostring(control_issue or ""), path)
      end,
      marker_present = function()
        -- Trust the outcome marker ONLY on a bot-authored comment on the control issue.
        local bot = M.bot_login()
        local view = M.gh_read(M.gh_issue_view_argv(M.tracker_repo(), tostring(control_issue or ""), "comments"))
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
