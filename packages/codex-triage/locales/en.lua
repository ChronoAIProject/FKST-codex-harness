-- codex-triage locale catalog: flat {key = UTF-8 string}; t(key) reads this.
-- The score/dedup pipeline is machine-internal (no user-facing prose on the read
-- side), so the catalog only carries the candidate summary string; en.lua is the
-- reference catalog any future locale must fully cover.
return {
  ["codex-triage.candidate.raised"] = "Raised codex candidate {dedup_key} (score {score}).",
}
