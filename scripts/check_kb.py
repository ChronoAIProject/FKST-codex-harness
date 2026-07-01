#!/usr/bin/env python3
# scripts/check_kb.py - knowledge-base (corpus / learning-bank) validator.
#
# Added in Phase 6 (NOT part of the init-package-repo scaffold; see check_repo.py
# for the emitted repo-guard companion). Wired into `scripts/run.sh check`
# alongside check_repo.py. Validates the data/ knowledge bases documented in
# docs/KNOWLEDGE-BASE.md, in three tiers with different failure semantics:
#
#   COMMITTED  (bootstrap/seed corpora + the current distilled rubric) -> HARD:
#              must exist, parse, carry required fields, well-formed source_ref
#              where required, row counts > 0, and NO raw body/diff leakage in the
#              normalized (source_ref-bearing) corpora. Missing/invalid => FAIL.
#   GENERATED  (relearn-produced styleguides / rubric_history / relearn_log) ->
#              OPTIONAL: they only exist after a relearn cycle. Validate SHAPE if
#              present; NEVER fail on absence.
#   DURABLE    (gitignored raw outcomes + kb staging under .fkst/) -> IGNORED:
#              never read, never validated, never a failure source here.
#
# Pure stdlib, no network, read-only over data/. Matches check_repo.py posture:
# collect problems, print them with a `check_kb.py:` prefix, exit 1 if any.
from pathlib import Path
import json
import re
import sys


# owner/repo#number  (e.g. openai/codex#29189)
SOURCE_REF_RE = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#\d+$")

# Fields that would mean a raw issue body / PR diff leaked into a normalized,
# source_ref-bearing corpus (payload discipline: bodies/diffs are re-fetched via
# source_ref, never inlined - ARCHITECTURE.md §5). worked_on_full.jsonl is the
# deliberate full-body SEED and is exempt from this check.
BODY_LEAK_FIELDS = {
    "body",
    "diff",
    "patch",
    "raw",
    "text",
    "file_contents",
    "comment_body",
    "thread_text",
}


class Report:
    """Accumulates errors (fail the run) and OK notes (printed on success)."""

    def __init__(self) -> None:
        self.errors: list[str] = []
        self.notes: list[str] = []

    def error(self, message: str) -> None:
        self.errors.append(message)

    def note(self, message: str) -> None:
        self.notes.append(message)


def iter_jsonl(path: Path, report: Report):
    """Yield (lineno, obj) for each non-blank line; report parse errors."""
    with path.open(encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                yield lineno, json.loads(line)
            except json.JSONDecodeError as exc:
                report.error(f"{path.name}:{lineno}: invalid JSON ({exc})")


def check_source_ref(obj: dict, expected_kind: str) -> str | None:
    """Return an error string if source_ref is missing/malformed, else None."""
    sref = obj.get("source_ref")
    if not isinstance(sref, dict):
        return "missing or non-object source_ref"
    kind, ref = sref.get("kind"), sref.get("ref")
    if kind != expected_kind:
        return f"source_ref.kind {kind!r} != expected {expected_kind!r}"
    if not isinstance(ref, str) or not SOURCE_REF_RE.match(ref):
        return f"source_ref.ref {ref!r} not owner/repo#number"
    return None


def check_no_leak(obj: dict) -> list[str]:
    """Return the raw-body/diff fields present in a normalized-corpus row."""
    return sorted(set(obj.keys()) & BODY_LEAK_FIELDS)


# --------------------------------------------------------------------------
# COMMITTED corpora (hard requirements)
# --------------------------------------------------------------------------
def check_area_rubric(path: Path, report: Report) -> None:
    if not path.is_file():
        report.error(f"{path.name}: missing required committed rubric")
        return
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        report.error(f"{path.name}: invalid JSON ({exc})")
        return
    if not isinstance(data, dict):
        report.error(f"{path.name}: top-level must be an object")
        return
    for key in ("importance_signal", "areas"):
        if key not in data:
            report.error(f"{path.name}: missing required key {key!r}")
    areas = data.get("areas")
    if not isinstance(areas, dict) or not areas:
        report.error(f"{path.name}: 'areas' must be a non-empty object")
        return
    for name, entry in areas.items():
        if not isinstance(entry, dict):
            report.error(f"{path.name}: area {name!r} is not an object")
            continue
        for field in ("fix_rate", "tier"):
            if field not in entry:
                report.error(f"{path.name}: area {name!r} missing {field!r}")
    report.note(f"OK: {path.name} ({len(areas)} areas)")


def check_open_issue_clusters(path: Path, report: Report) -> None:
    if not path.is_file():
        report.error(f"{path.name}: missing required committed corpus")
        return
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        report.error(f"{path.name}: invalid JSON ({exc})")
        return
    if not isinstance(data, list) or not data:
        report.error(f"{path.name}: must be a non-empty array of clusters")
        return
    for i, cluster in enumerate(data):
        if not isinstance(cluster, dict):
            report.error(f"{path.name}[{i}]: cluster is not an object")
            continue
        rep = cluster.get("rep")
        if not isinstance(rep, dict) or "n" not in rep:
            report.error(f"{path.name}[{i}]: cluster 'rep' missing or has no 'n'")
        members = cluster.get("members")
        if not isinstance(members, list) or not members:
            report.error(f"{path.name}[{i}]: cluster 'members' missing/empty")
    report.note(f"OK: {path.name} ({len(data)} clusters)")


def check_corpus_selection(path: Path, report: Report) -> None:
    rows = 0
    for lineno, obj in iter_jsonl(path, report):
        rows += 1
        if not isinstance(obj, dict):
            report.error(f"{path.name}:{lineno}: row is not an object")
            continue
        err = check_source_ref(obj, "issue")
        if err:
            report.error(f"{path.name}:{lineno}: {err}")
        for field in ("label", "type"):
            if not obj.get(field):
                report.error(f"{path.name}:{lineno}: missing {field!r}")
        leaks = check_no_leak(obj)
        if leaks:
            report.error(f"{path.name}:{lineno}: raw payload leak {leaks}")
    if rows == 0:
        report.error(f"{path.name}: 0 rows (expected > 0)")
    else:
        report.note(f"OK: {path.name} ({rows} rows)")


def check_corpus_engagement(path: Path, report: Report) -> None:
    rows = 0
    for lineno, obj in iter_jsonl(path, report):
        rows += 1
        if not isinstance(obj, dict):
            report.error(f"{path.name}:{lineno}: row is not an object")
            continue
        err = check_source_ref(obj, "issue")
        if err:
            report.error(f"{path.name}:{lineno}: {err}")
        if not obj.get("outcome"):
            report.error(f"{path.name}:{lineno}: missing 'outcome'")
        moves = obj.get("thread_moves")
        if not isinstance(moves, list):
            report.error(f"{path.name}:{lineno}: 'thread_moves' must be a list")
            moves = []
        leaks = check_no_leak(obj)
        for move in moves:
            if isinstance(move, dict):
                leaks += check_no_leak(move)
        if leaks:
            report.error(f"{path.name}:{lineno}: raw payload leak {sorted(set(leaks))}")
    if rows == 0:
        report.error(f"{path.name}: 0 rows (expected > 0)")
    else:
        report.note(f"OK: {path.name} ({rows} rows)")


def check_corpus_pr_style(path: Path, report: Report) -> None:
    rows = 0
    for lineno, obj in iter_jsonl(path, report):
        rows += 1
        if not isinstance(obj, dict):
            report.error(f"{path.name}:{lineno}: row is not an object")
            continue
        err = check_source_ref(obj, "pull")
        if err:
            report.error(f"{path.name}:{lineno}: {err}")
        if "merged" not in obj:
            report.error(f"{path.name}:{lineno}: missing 'merged'")
        paths = obj.get("touched_paths")
        if paths is not None and (
            not isinstance(paths, list)
            or not all(isinstance(p, str) for p in paths)
        ):
            report.error(f"{path.name}:{lineno}: 'touched_paths' must be a list of path strings")
        leaks = check_no_leak(obj)
        if leaks:
            report.error(f"{path.name}:{lineno}: raw payload leak {leaks}")
    if rows == 0:
        report.error(f"{path.name}: 0 rows (expected > 0)")
    else:
        report.note(f"OK: {path.name} ({rows} rows)")


def check_worked_on_full(path: Path, report: Report) -> None:
    # Deliberate full-body SEED corpus: full issue bodies are expected here, so
    # this is EXEMPT from the leak check. Validate identity fields + row count.
    rows = 0
    for lineno, obj in iter_jsonl(path, report):
        rows += 1
        if not isinstance(obj, dict):
            report.error(f"{path.name}:{lineno}: row is not an object")
            continue
        if not isinstance(obj.get("number"), int):
            report.error(f"{path.name}:{lineno}: 'number' missing or not an int")
        if not obj.get("title"):
            report.error(f"{path.name}:{lineno}: missing 'title'")
    if rows == 0:
        report.error(f"{path.name}: 0 rows (expected > 0)")
    else:
        report.note(f"OK: {path.name} ({rows} rows)")


def check_repo_structure(path: Path, report: Report) -> None:
    if not path.is_file():
        report.error(f"{path.name}: missing required committed corpus")
        return
    text = path.read_text(encoding="utf-8")
    if not text.strip():
        report.error(f"{path.name}: is empty")
        return
    low = text.lower()
    if "area" not in low or "crate" not in low:
        report.error(f"{path.name}: missing the area->crate mapping (no 'area'/'crate')")
        return
    report.note(f"OK: {path.name} ({len(text.splitlines())} lines)")


# --------------------------------------------------------------------------
# GENERATED distilled banks (optional: shape-only IF present; never on absence)
# --------------------------------------------------------------------------
def check_generated(learning: Path, report: Report) -> None:
    if not learning.is_dir():
        report.note("note: data/learning/ absent - no generated banks to check")
        return

    for name in ("engagement_styleguide.md", "pr_styleguide.md"):
        path = learning / name
        if path.is_file():
            if path.read_text(encoding="utf-8").strip():
                report.note(f"OK: data/learning/{name} present (shape ok)")
            else:
                report.error(f"data/learning/{name}: present but empty")

    history = learning / "rubric_history"
    if history.is_dir():
        snapshots = sorted(history.glob("area_rubric.*.json"))
        for snap in snapshots:
            try:
                data = json.loads(snap.read_text(encoding="utf-8"))
            except json.JSONDecodeError as exc:
                report.error(f"data/learning/rubric_history/{snap.name}: invalid JSON ({exc})")
                continue
            if not isinstance(data, dict) or not isinstance(data.get("areas"), dict):
                report.error(
                    f"data/learning/rubric_history/{snap.name}: not a rubric (needs 'areas')"
                )
        if snapshots:
            report.note(f"OK: rubric_history/ ({len(snapshots)} snapshot(s))")

    relearn_log = learning / "relearn_log.jsonl"
    if relearn_log.is_file():
        rows = 0
        for lineno, obj in iter_jsonl(relearn_log, report):
            rows += 1
            if not isinstance(obj, dict):
                report.error(f"relearn_log.jsonl:{lineno}: row is not an object")
        report.note(f"OK: data/learning/relearn_log.jsonl ({rows} row(s))")


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    data = root / "data"
    if not data.is_dir():
        print("check_kb.py: data/ directory not found", file=sys.stderr)
        sys.exit(1)

    report = Report()

    # (a) COMMITTED bootstrap/seed corpora + the current distilled rubric (HARD).
    check_area_rubric(data / "area_rubric.json", report)
    check_open_issue_clusters(data / "open_issue_clusters.json", report)
    check_corpus_selection(data / "corpus_selection.jsonl", report)
    check_corpus_engagement(data / "corpus_engagement.jsonl", report)
    check_corpus_pr_style(data / "corpus_pr_style.jsonl", report)
    check_worked_on_full(data / "worked_on_full.jsonl", report)
    check_repo_structure(data / "codex-repo-structure.md", report)

    # (b) GENERATED distilled banks (OPTIONAL: shape only, never fail on absence).
    check_generated(data / "learning", report)

    # (c) GITIGNORED durable staging (raw outcomes / kb staging) is intentionally
    #     never read here - it is program-only scratch and never a failure source.

    if report.errors:
        for message in report.errors:
            print(f"check_kb.py: {message}", file=sys.stderr)
        print(f"check_kb.py: FAILED ({len(report.errors)} problem(s))", file=sys.stderr)
        sys.exit(1)

    for note in report.notes:
        print(note)
    print("OK: knowledge bases validated")


if __name__ == "__main__":
    main()
