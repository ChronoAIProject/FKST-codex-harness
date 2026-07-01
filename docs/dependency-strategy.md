<div align="center">

[![English](https://img.shields.io/badge/English-1f6feb?style=for-the-badge)](dependency-strategy.md)&nbsp;[![简体中文](https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-8b949e?style=for-the-badge)](dependency-strategy.zh-CN.md)

</div>

# Dependency strategy (R2): VENDORED `workflow` library

*Decided empirically by Task C, 2026-06-30. Authoritative spec §8; addendum R2.*

## Decision

The `workflow` library is **VENDORED** into `libraries/workflow/` as a minimal,
real-manifest subset (just `saga.lua`). It is NOT pinned via
`fkst.workspace.toml [[external_sources]]` + `fkst.lock`.

## Why vendor (the external-source pin was rejected)

`persistence_class = "saga"` requires the departments to `require("workflow.saga")`
and call `.department(...)`, so a `workflow` library must resolve in-harness. The
approved DEFAULT (addendum R2) was to PIN the real platform from the local
`fkst-packages` checkout (= `ChronoAIProject/fkst-packages`).

That pin was attempted and **rejected by the engine**, empirically:

1. Declared `[[external_sources]]` with `git = <local fkst-packages>`,
   `rev = 8704a642f9c61023a2bbb50fade0c24483680eeb`, `libraries = ["workflow", "contract"]`.
2. `fkst-framework deps lock` resolved the tree + per-library export hashes and wrote
   `fkst.lock`, BUT validation then failed with:
   ```
   external source `fkst-packages` does not allow library `workflow`
   ```
3. Root cause (substrate `manifest.rs::add_external_units`): an external source only
   admits **publishable** libraries (`if !library.publishable { continue }`); a
   non-admitted library lands in `denied_external_libraries` and consuming it
   fail-closes. The upstream `workflow` library declares `[library]` WITHOUT
   `publishable = true` and `[visibility] public = false`, so it cannot cross an
   external-source boundary. (`contract` IS `publishable = true` and would resolve.)
4. `fkst-packages` is read/pin/vendor-only here — the `publishable` flag cannot be
   flipped at the source — so the pin path cannot resolve `workflow`. This is exactly
   the "cross-repo external source that nothing resolves" fragility the addendum
   anticipated.

## What was vendored (real, not fake)

- `libraries/workflow/saga.lua` — **byte-identical** copy of
  `fkst-packages@8704a642…:libraries/workflow/saga.lua`. It has **zero external
  requires** (no `contract` dependency), so it is the minimal conformant subset; the
  full upstream `workflow` (codex/oracle/sweep/dead_letter/liveness/…) and its
  transitive `contract` are intentionally NOT vendored.
- `libraries/workflow/fkst.toml` — real `kind = "library"` manifest
  (`[library]` meta, `[exports] public = ["workflow.*"]`, `[visibility] public = false`,
  empty `[lib_deps]`).
- `libraries/workflow/VENDORED.pin` — provenance: source repo, source SHA, source path.

Both packages declare `[lib_deps] libraries = ["workflow"]`.

## Proof it resolves + conforms

```
fkst-framework deps --project-root .            # PASS: codex-{triage,saga} -> workflow
fkst-framework conformance ... codex-triage     # PASS 7/7 (flat single-root)
fkst-framework conformance ... codex-saga +     # PASS 8/8, incl.
  codex-triage (composed)                       #   conformance-function core.saga_conformance_errors -> no errors
scripts/run.sh check                            # exit 0
scripts/run.sh test                             # exit 0 (self-test + per-pkg + composed + G5)
```

## Refresh

Re-copy `libraries/workflow/saga.lua` from the source repo at the pinned SHA (or a
newer reviewed SHA) and update `source_sha` in `libraries/workflow/VENDORED.pin`. If
the upstream `workflow` library is ever published (`publishable = true`), the
external-source pin in §8 becomes viable and this vendoring can be revisited.
