-- codex-learn locale catalog: flat {key = UTF-8 string}; t(key) reads this.
-- The re-derivation pipeline is machine-internal; the only outward prose is the
-- generated styleguide headers (the human-readable banks codex-saga retrieves).
-- en.lua is the reference catalog any future locale must fully cover.
return {
  ["codex-learn.relearn.cycle"] = "Re-derivation cycle {ts}: {status} (AUC {auc}, monotonic {monotonic}).",
  ["codex-learn.styleguide.engagement.title"] = "Engagement styleguide (induced from successful issue threads)",
  ["codex-learn.styleguide.engagement.preamble"] = "Comment on an issue the way these moves succeeded on similar issues; obey these rules.",
  ["codex-learn.styleguide.pr.title"] = "PR styleguide (induced from merged pull requests)",
  ["codex-learn.styleguide.pr.preamble"] = "Shape the fix the way merged PRs on this repo were shaped; obey these rules.",
}
