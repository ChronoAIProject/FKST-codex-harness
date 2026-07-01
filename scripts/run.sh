#!/usr/bin/env bash
# =============================================================================
# scripts/run.sh - multi-package dev/CI runner for FKST-codex-harness.
#
# DELIBERATE, NARROW EXCEPTION to architecture spec §2, which says the scaffold
# files emitted by `fkst-framework init-package-repo` should not be hand-written.
# This file REPLACES the emitted scripts/run.sh. The emitted runner drives a
# SINGLE folded root (`--project-root $repo --package-root $repo`) and therefore
# CANNOT drive the multi-package `packages/` topology that spec §2 mandates
# (packages/codex-triage flat + packages/codex-saga composed, with cross-package
# [event_deps] composed conformance). This is an adaptation of the proven
# marketing-tbd/fkst-packages/scripts/run.sh (R1, approved in PHASE2_ADDENDUM):
# per-package --package-root, composed-deps walk, self-test, report-json (G5)
# coverage, and the documented BIN resolution order. The operational scaffold
# MACHINERY (check_repo.py, ci.yml, .fkst-substrate-ref, .gitignore, README.md) is
# left EXACTLY as emitted. The one other touched file is env.example, which received
# a clearly-marked, append-only two-plane config block (spec §4; approved in
# PHASE2_ADDENDUM / D2 as a documented generated-template update, NOT a rewrite).
# See docs/dependency-strategy.md.
#
#   scripts/run.sh check    hermetic repo guards (check_repo.py) + KB validation
#                           (check_kb.py, Phase 6) + `deps`
#   scripts/run.sh test     check + self-test + per-package conformance/test +
#                           composed conformance + G5 report-json coverage
#   scripts/run.sh supervise [pkg]
#                           run the FKST event loop over the packages/ graph via
#                           the engine `supervise` subcommand. DRY-RUN unless the
#                           host sets FKST_GITHUB_WRITE=1. Uses STABLE state roots
#                           (.fkst/durable = redb, survives restarts; .fkst/runtime
#                           scratch); go-live config from .fkst/env. [pkg] scopes to
#                           one composed graph (pkg + [event_deps]); default = all.
#
# fkst-framework BIN resolution order (priority):
#   $BIN > repo .fkst/env `BIN=` > repo fkst.env `BIN=` > PATH (fkst-framework) >
#   sibling ../FKST-substrate (or ../fkst-substrate) target/debug/fkst-framework
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_ROOT="$ROOT/packages"

# ---------------------------------------------------------------------------
# BIN resolution
# ---------------------------------------------------------------------------
bin_from_env_file() {
  local file="$1" line
  [ -f "$file" ] || return 1
  line="$(grep -E '^[[:space:]]*BIN=' "$file" | tail -1 || true)"
  [ -n "$line" ] || return 1
  line="${line#*BIN=}"
  line="${line%\"}"; line="${line#\"}"
  printf '%s\n' "$line"
}

resolve_bin() {
  if [ -n "${BIN:-}" ]; then return 0; fi
  local candidate
  if candidate="$(bin_from_env_file "$ROOT/.fkst/env")"; then BIN="$candidate"; return 0; fi
  if candidate="$(bin_from_env_file "$ROOT/fkst.env")"; then BIN="$candidate"; return 0; fi
  if command -v fkst-framework >/dev/null 2>&1; then BIN="$(command -v fkst-framework)"; return 0; fi
  local sibling
  for sibling in "$ROOT/../FKST-substrate" "$ROOT/../fkst-substrate"; do
    if [ -x "$sibling/target/debug/fkst-framework" ]; then
      BIN="$sibling/target/debug/fkst-framework"; return 0
    fi
  done
  echo "error: cannot resolve fkst-framework BIN (set BIN, .fkst/env BIN=, PATH, or build ../FKST-substrate)" >&2
  if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "  CI must build fkst-substrate and inject BIN; run.sh will not build in CI." >&2
  fi
  return 1
}

# ---------------------------------------------------------------------------
# composition helpers (engine manifest CLI: composed-deps exit 0=composed,
# 10=flat, prints sibling package names one per line)
# ---------------------------------------------------------------------------
is_composed() {
  local pkg="$1" rc=0
  "$BIN" manifest composed-deps --manifest "$pkg/fkst.toml" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;   # composed
    10) return 1 ;;  # flat
    *) echo "error: manifest composed-deps failed for $pkg" >&2; return 2 ;;
  esac
}

package_root_for_name() {
  local name="$1"
  [ -d "$PACKAGES_ROOT/$name" ] && { printf '%s\n' "$PACKAGES_ROOT/$name"; return 0; }
  return 1
}

# Recursively collect a composed package + its [event_deps] siblings into COMPOSED_SEEN.
collect_composed_package() {
  local name="$1" pkg dep deps rc
  pkg="$(package_root_for_name "$name")" || { echo "error: composed dep not found: $name" >&2; return 1; }
  case " ${COMPOSED_SEEN[*]-} " in *" $name "*) return 0 ;; esac
  COMPOSED_SEEN+=("$name")
  rc=0; deps="$("$BIN" manifest composed-deps --manifest "$pkg/fkst.toml" 2>/dev/null)" || rc=$?
  case "$rc" in
    0) while IFS= read -r dep || [ -n "$dep" ]; do
         [ -n "$dep" ] || continue
         collect_composed_package "$dep" || return 1
       done <<< "$deps" ;;
    10) return 0 ;;
    *) echo "error: composed-deps failed for $pkg" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------
cmd_check() {
  local fail=0
  python3 -B "$ROOT/scripts/check_repo.py" || fail=1
  # Phase 6, minimal addition: validate the data/ knowledge bases (committed
  # corpora + optional generated learning banks) via check_kb.py, alongside the
  # as-emitted check_repo.py repo guards. No BIN needed (read-only over data/);
  # see docs/KNOWLEDGE-BASE.md. Durable/gitignored staging is never touched.
  python3 -B "$ROOT/scripts/check_kb.py" || fail=1
  if [ "$fail" -eq 0 ]; then
    resolve_bin || return 1
    "$BIN" deps --project-root "$ROOT" || fail=1
  fi
  return "$fail"
}

# ---------------------------------------------------------------------------
# G5: every packages/**/tests/*_test.lua and packages/**/departments/*/*_test.lua
# must yield >=1 passing report-json test
# ---------------------------------------------------------------------------
check_test_file_coverage() {
  local report_dir="$1"
  python3 - "$ROOT" "$report_dir" <<'PY'
import json, sys
from pathlib import Path
root, report_dir = Path(sys.argv[1]), Path(sys.argv[2])
packages_root = root / "packages"
expected = set()
for path in packages_root.rglob("*_test.lua"):
    rel = path.relative_to(packages_root)
    parts = rel.parts
    # packages/<pkg>/tests/*_test.lua  OR  packages/<pkg>/departments/<d>/*_test.lua
    if len(parts) >= 3 and parts[1] == "tests":
        expected.add(f"packages/{rel.as_posix()}")
    elif len(parts) >= 4 and parts[1] == "departments":
        expected.add(f"packages/{rel.as_posix()}")
actual = set()
for report_path in sorted(report_dir.glob("*.json")):
    report = json.load(report_path.open(encoding="utf-8"))
    if report.get("schema") != "fkst.test.report.v1":
        raise SystemExit(f"bad test report schema in {report_path}: {report.get('schema')!r}")
    summary = report.get("summary") or {}
    if int(summary.get("failed", 0)) != 0:
        raise SystemExit(f"test report contains failures in {report_path}")
    for test in report.get("tests", []):
        if not isinstance(test, dict) or test.get("status") != "pass":
            continue
        owner, file_name = test.get("owner_namespace"), test.get("file")
        if not isinstance(owner, str) or not isinstance(file_name, str):
            continue
        if not file_name.endswith("_test.lua"):
            continue
        if not (file_name.startswith("tests/") or file_name.startswith("departments/")):
            continue
        actual.add(f"packages/{owner}/{file_name}")
missing = sorted(expected - actual)
if missing:
    sys.stderr.write("error: G5 engine test coverage failed; these *_test.lua produced zero report-json pass results:\n")
    for m in missing:
        sys.stderr.write(f"  {m}\n")
    raise SystemExit(1)
print(f"OK: G5 every *_test.lua produced an engine report-json pass ({len(expected)} file(s))")
PY
}

# ---------------------------------------------------------------------------
# composed conformance across each composed package + its event_deps graph
# ---------------------------------------------------------------------------
cmd_test_composed() {
  local pkg name args project_root
  COMPOSED_SEEN=()
  for pkg in "$PACKAGES_ROOT"/*/; do
    [ -d "$pkg" ] || continue
    if is_composed "${pkg%/}"; then
      collect_composed_package "$(basename "${pkg%/}")" || return 1
    fi
  done
  if [ "${#COMPOSED_SEEN[@]}" -eq 0 ]; then
    echo "no composed packages matched"
    return 0
  fi
  project_root="$(package_root_for_name "${COMPOSED_SEEN[0]}")" || return 1
  args=()
  for name in "${COMPOSED_SEEN[@]}"; do
    args+=(--package-root "$(package_root_for_name "$name")")
  done
  echo "=== composed conformance (${COMPOSED_SEEN[*]}) ==="
  "$BIN" conformance --project-root "$project_root" "${args[@]}"
}

# ---------------------------------------------------------------------------
# test
# ---------------------------------------------------------------------------
cmd_test() {
  local fail=0 ran=0 pkg name report_dir _chk

  # check first; abort on failure.
  if ! _chk="$(cmd_check 2>&1)"; then printf '%s\n' "$_chk" >&2; echo "FAILED: check did not pass" >&2; exit 1; fi
  resolve_bin || exit 1

  # hermetic, fail-closed posture: fresh runtime + durable roots, no real egress.
  trap 'rm -rf "${HRT:-}" "${HDR:-}"' EXIT
  HRT="$(mktemp -d "${TMPDIR:-/tmp}/fkst-rt.XXXXXX")"
  HDR="$(mktemp -d "${TMPDIR:-/tmp}/fkst-durable.XXXXXX")"
  export FKST_RUNTIME_ROOT="$HRT"
  export FKST_DURABLE_ROOT="$HDR"
  unset FKST_GITHUB_WRITE || true
  echo "test hermetic: FKST_RUNTIME_ROOT=$HRT FKST_DURABLE_ROOT=$HDR (FKST_GITHUB_WRITE unset)"

  report_dir="$(mktemp -d "${TMPDIR:-/tmp}/fkst-reports.XXXXXX")"

  echo "=== self-test ==="
  "$BIN" --self-test || fail=$((fail + 1))

  for pkg in "$PACKAGES_ROOT"/*/; do
    [ -d "$pkg" ] || continue
    pkg="${pkg%/}"
    name="$(basename "$pkg")"
    echo "=== $name ==="
    ran=$((ran + 1))
    if is_composed "$pkg"; then
      echo "skip single-package conformance for composed package: $name"
    else
      if ! "$BIN" conformance --project-root "$ROOT" --package-root "$pkg"; then
        fail=$((fail + 1)); continue
      fi
    fi
    if ! "$BIN" test --project-root "$ROOT" --package-root "$pkg" --report-json "$report_dir/$name.json"; then
      fail=$((fail + 1))
    fi
  done

  if [ "$ran" -eq 0 ]; then echo "no packages matched" >&2; exit 1; fi

  if [ "$fail" -eq 0 ]; then cmd_test_composed || fail=$((fail + 1)); fi
  if [ "$fail" -eq 0 ]; then check_test_file_coverage "$report_dir" || fail=$((fail + 1)); fi

  rm -rf "$report_dir"
  if [ "$fail" -ne 0 ]; then echo "FAILED: $fail failure(s) across $ran package(s)" >&2; exit 1; fi
  echo "OK: $ran package(s)"
}

# ---------------------------------------------------------------------------
# supervise - the real FKST event loop (README go-live). Drives the packages/
# graph via the engine `supervise` subcommand. DRY-RUN unless the host opted into
# real writes (FKST_GITHUB_WRITE=1, via .fkst/env or the environment). Uses STABLE
# state roots: .fkst/durable is the redb saga truth and MUST persist across restarts
# (never the hermetic scratch that `test` clears). Optional [pkg] scopes to one
# composed graph (pkg + its [event_deps]); default supervises every package.
# ---------------------------------------------------------------------------
cmd_supervise() {
  resolve_bin || exit 1

  # Go-live config (two-plane targets, gate policy, device bot identity, and the
  # optional FKST_GITHUB_WRITE opt-in) from .fkst/env when present; a value already
  # in the environment still wins (set -a exports every assignment sourced here).
  if [ -f "$ROOT/.fkst/env" ]; then set -a; . "$ROOT/.fkst/env"; set +a; fi

  # Stable state roots. Durable (redb) MUST survive restarts; honor a pre-set root,
  # else the repo default. This is deliberately NOT the mktemp scratch `test` uses.
  export FKST_RUNTIME_ROOT="${FKST_RUNTIME_ROOT:-$ROOT/.fkst/runtime}"
  export FKST_DURABLE_ROOT="${FKST_DURABLE_ROOT:-$ROOT/.fkst/durable}"
  mkdir -p "$FKST_RUNTIME_ROOT" "$FKST_DURABLE_ROOT"

  # Package roots: a scoped composed graph if [pkg] is given, else every package.
  local args=() names=() name pkg
  if [ -n "${1:-}" ]; then
    COMPOSED_SEEN=(); collect_composed_package "$1" || exit 1
    names=("${COMPOSED_SEEN[@]}")
  else
    for pkg in "$PACKAGES_ROOT"/*/; do [ -d "$pkg" ] || continue; names+=("$(basename "${pkg%/}")"); done
  fi
  for name in "${names[@]}"; do args+=(--package-root "$(package_root_for_name "$name")"); done

  local mode="dry-run (no external writes)"
  [ "${FKST_GITHUB_WRITE:-}" = "1" ] && mode="REAL - OUTWARD WRITES ENABLED"
  echo "=== supervise ==="
  echo "  project-root : $ROOT"
  echo "  packages     : ${names[*]}"
  echo "  durable(redb): $FKST_DURABLE_ROOT"
  echo "  runtime      : $FKST_RUNTIME_ROOT"
  echo "  contrib      : ${FKST_CONTRIB_TARGET:-openai/codex} (read + gated propose)"
  echo "  write mode   : $mode"
  [ "${FKST_GITHUB_WRITE:-}" = "1" ] && echo "  WARNING: gate/engage/open_pr may write to GitHub this run."
  exec "$BIN" supervise --project-root "$ROOT" "${args[@]}" --framework-bin "$BIN"
}

usage() {
  cat <<'EOF'
scripts/run.sh check              repo guards (check_repo.py) + KB validation (check_kb.py) + engine deps
scripts/run.sh test               check + self-test + per-package conformance/test + composed conformance + G5 coverage
scripts/run.sh supervise [pkg]    run the FKST event loop over packages/ (DRY-RUN unless FKST_GITHUB_WRITE=1);
                                  stable .fkst/durable (redb) + .fkst/runtime; config from .fkst/env; [pkg] scopes one composed graph
EOF
}

main() {
  case "${1:-}" in
    check) shift; cmd_check "$@" ;;
    test) shift; cmd_test "$@" ;;
    supervise) shift; cmd_supervise "$@" ;;
    -h|--help|help|"") usage ;;
    *) echo "unknown subcommand: $1" >&2; usage; exit 1 ;;
  esac
}

main "$@"
