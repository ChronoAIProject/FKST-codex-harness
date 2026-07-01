-- codex-saga locale catalog: flat {key = UTF-8 string}; t(key[, vars]) reads this.
-- These are the OUTWARD strings (spec §10 output contract): the gh issue/comment
-- and PR body templates, the gate refusal reasons, the AI-disclosure line, and the
-- CLA text. Marker/protocol sentinels (HTML comments) are CODE, in core/markers.lua,
-- NOT catalog content (the engine rejects `<!-- fkst:` tokens in locale values).
-- Interpolation placeholders use {name} with name in [A-Za-z0-9_]+.
return {
  -- AI disclosure (mandatory on every public post, spec §10 gate7).
  ["codex-saga.engage.disclose_ai"] = "This analysis was prepared with AI assistance.",

  -- Outward issue/comment dossier (the §3 winning template: repro + root cause +
  -- impact + approach as options + defer + disclosure).
  ["codex-saga.engage.heading"] = "Diagnosis and proposed approach",
  ["codex-saga.engage.root_cause_label"] = "Root cause",
  ["codex-saga.engage.impact_label"] = "Impact",
  ["codex-saga.engage.precedent_label"] = "Precedent",
  ["codex-saga.engage.precedent_none"] = "no closely analogous merged fix found in the worked-on corpus",
  ["codex-saga.engage.approach"] = "Approach: happy to implement whichever direction you prefer; I have a focused fix ready on a fork branch and can open a PR once invited.",
  ["codex-saga.engage.modeled_on"] = "This response is modeled on {count} similar contributions that earned maintainer engagement.",

  -- Control issue (saga tracker on this harness repo; mirrors saga state on GitHub).
  ["codex-saga.control.title"] = "codex-saga: {dedup_key}",
  ["codex-saga.control.body"] = "Program-produced saga control issue. State transitions are recorded by the harness as labels and markers; do not hand-edit.",

  -- Gate refusal reasons (the WHY carried by the terminal drop, spec §10).
  ["codex-saga.gate.refuse_security"] = "Security or safety issue: routed privately to security@openai.com and never posted publicly.",
  ["codex-saga.gate.refuse_consensus"] = "Multi-angle consensus did not approve this engagement.",
  ["codex-saga.gate.refuse_volume_cap"] = "Daily public engagement cap reached; deferring this engagement.",
  ["codex-saga.gate.refuse_disclosure"] = "AI-disclosure is disabled; refusing to post without disclosing AI assistance.",
  ["codex-saga.gate.refuse_invite_policy"] = "Invitation precondition is disabled; refusing to engage without the no-uninvited-PR safety in place.",

  -- Diagnose drop reasons.
  ["codex-saga.diagnose.needs_info_no_fork"] = "Cannot reproduce locally: no fork checkout is configured.",
  ["codex-saga.diagnose.needs_info_not_reproduced"] = "Could not reproduce the issue locally; dropping to needs_info pending more information.",

  -- Implement (the write-class fix step) drop reasons.
  ["codex-saga.implement.needs_info_no_fork"] = "Cannot write a fix locally: no fork checkout is configured.",
  ["codex-saga.implement.needs_info_no_fix"] = "Could not write a focused fix on the fork; dropping to needs_info pending more information.",

  -- Track (the terminal outcome recorder) heading on the durable control issue.
  ["codex-saga.track.heading"] = "Attempt outcome (program-produced; recorded by the harness for the learning loop).",

  -- PR body + CLA (only after a recorded invitation, spec §10 gate3).
  ["codex-saga.pr.heading"] = "What and why",
  ["codex-saga.pr.linked"] = "This change addresses the diagnosed issue and was developed on a fork.",
  ["codex-saga.pr.cla"] = "I have read the CLA Document and I hereby sign the CLA",
}
