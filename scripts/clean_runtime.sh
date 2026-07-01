#!/usr/bin/env bash
# clean_runtime.sh — clear the CLEARABLE runtime scratch between supervise sessions.
#
# Fixes the cross-session leak where a killed run's scratch (stale department locks +
# the codex-adoption result cache) makes a fresh run short-circuit: e.g. a candidate's
# diagnosis returns a CACHED "not reproduced" in ~2s instead of running codex.
#
# Scope discipline (CLAUDE.md §two-plane): this touches ONLY $FKST_RUNTIME_ROOT
# (clearable engine scratch). It NEVER touches:
#   - $FKST_DURABLE_ROOT  (redb delivery journal + outcomes.jsonl + issue mirror) — live program state
#   - codex-fork          (the owned code checkout)
# Run it while supervise is STOPPED. Safe to run repeatedly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RT="${FKST_RUNTIME_ROOT:-$ROOT/.fkst/runtime}"

if pgrep -f 'fkst-framework supervise' >/dev/null 2>&1; then
  echo "refusing: 'fkst-framework supervise' is running — stop it first (its locks are live)." >&2
  exit 1
fi

echo "clean_runtime: $RT"
for sub in locks logs/codex-adoption worktrees; do
  d="$RT/$sub"
  if [ -d "$d" ]; then
    n=$(find "$d" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
    rm -rf "${d:?}/"* 2>/dev/null || true
    echo "  cleared $sub ($n item(s))"
  fi
done
echo "clean_runtime: done — durable state under ${FKST_DURABLE_ROOT:-$ROOT/.fkst/durable} untouched."
