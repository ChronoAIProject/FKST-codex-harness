#!/usr/bin/env python3
# scripts/reconcile_issues.py - out-of-band issue-MIRROR reconcile (the "fresh pull", done right).
#
# WHY THIS IS A SCRIPT, NOT A PACKAGE (FKST alignment): the mirror is a stateful producer
# (pagination checkpoint + watermark). The engine has no `stateful_adapter` persistence_class;
# the only stateful package class is `saga` (which conformance forces to carry restart-transition
# proofs + workflow.saga code) - mis-modeling a mirror. So the reconcile lives here as an
# operational producer (host cron/manual), and `codex-triage` (stateless_adapter) READS the mirror.
#
# It owns ALL reconcile state. codex-triage owns NONE - it never advances/repairs the watermark.
#
# Output (gitignored durable runtime, NEVER committed, NEVER data/):
#   $FKST_DURABLE_ROOT/codex-issue-mirror/open_issues.compact.jsonl   (one compact issue per line)
#   $FKST_DURABLE_ROOT/codex-issue-mirror/reconcile_state.json         (watermark + freshness)
#
# Discipline: COMPACT fields only (number/title/labels/reactions/updated_at/source_ref) - NEVER
# issue bodies. Page-by-page with per-page checkpoint (resume), retry+backoff, validate-before-swap
# (a partial/failed pull keeps the last-good mirror), atomic rename.
import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

PER_PAGE = 100
MAX_RETRIES = 5
MODEL_VERSION = "issue-mirror.v1"


def durable_root() -> Path:
    return Path(os.environ.get("FKST_DURABLE_ROOT") or ".fkst/durable")


def mirror_dir() -> Path:
    return durable_root() / "codex-issue-mirror"


def gh_get_page(repo: str, page: int):
    """Fetch ONE page of open issues, with retry+backoff. Returns the parsed JSON array."""
    endpoint = (
        f"repos/{repo}/issues?state=open&per_page={PER_PAGE}"
        f"&page={page}&sort=created&direction=asc"
    )
    last_err = ""
    for attempt in range(MAX_RETRIES):
        try:
            proc = subprocess.run(
                ["gh", "api", endpoint], capture_output=True, text=True, timeout=90
            )
        except subprocess.TimeoutExpired:
            last_err = "subprocess timeout (90s)"
            time.sleep(min(2 ** (attempt + 1), 30))
            continue
        if proc.returncode == 0:
            try:
                return json.loads(proc.stdout)
            except json.JSONDecodeError as exc:
                last_err = f"json: {exc}"
        else:
            last_err = (proc.stderr or "").strip()[:300]
            # rate-limit / secondary-limit / abuse: back off much harder.
            if any(s in last_err.lower() for s in ("rate limit", "secondary rate", "abuse", "403")):
                time.sleep(min(30 * (attempt + 1), 120))
                continue
        # generic transient: exponential backoff (2,4,8,16,30s)
        time.sleep(min(2 ** (attempt + 1), 30))
    raise RuntimeError(f"page {page} failed after {MAX_RETRIES} retries: {last_err}")


BODY_EXCERPT = 1000  # the rubric's anatomy score reads only body[:600]; carry a bit more.


def compact(issue: dict, repo: str) -> dict:
    """Project to the SMALL model. Carries a BOUNDED body EXCERPT (not the full body): the
    rubric's anatomy score reads body[:600], and the mirror is score_dedup's read-source (the
    live poll fed it bodies) - NOT an event payload. The raised codex_candidate stays bodyless."""
    return {
        "number": issue["number"],
        "title": issue.get("title", ""),
        "body": (issue.get("body") or "")[:BODY_EXCERPT],
        "labels": [lbl.get("name") for lbl in (issue.get("labels") or []) if lbl.get("name")],
        "reactions": (issue.get("reactions") or {}).get("total_count", 0),
        "updated_at": issue.get("updated_at"),
        "source_ref": {"kind": "external", "ref": f"{repo}#issues/{issue['number']}"},
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Reconcile the openai/codex open-issue mirror.")
    ap.add_argument("--repo", default=os.environ.get("FKST_CONTRIB_TARGET", "openai/codex"))
    ap.add_argument("--max-pages", type=int, default=0, help="cap pages (0 = all; for smoke tests)")
    ap.add_argument("--resume", action="store_true", help="continue from an existing checkpoint")
    ap.add_argument("--min-expected", type=int, default=50, help="reject a pull below this count")
    ap.add_argument("--max-expected", type=int, default=200000)
    ap.add_argument(
        "--allow-partial-swap",
        action="store_true",
        help="let a --max-pages PARTIAL run replace the LIVE mirror (testing only; "
        "otherwise a partial run writes a *.partial.* smoke artifact and never touches it)",
    )
    args = ap.parse_args()

    mdir = mirror_dir()
    ckpt = mdir / "checkpoint"
    model = mdir / "open_issues.compact.jsonl"
    state = mdir / "reconcile_state.json"
    ckpt.mkdir(parents=True, exist_ok=True)

    if not args.resume:
        for old in ckpt.glob("page-*.jsonl"):
            old.unlink()

    started = time.time()
    page = 1
    # resume: skip pages already checkpointed
    if args.resume:
        done_pages = sorted(int(p.stem.split("-")[1]) for p in ckpt.glob("page-*.jsonl"))
        page = (done_pages[-1] + 1) if done_pages else 1
        if done_pages:
            print(f"reconcile: resuming from page {page} ({len(done_pages)} pages checkpointed)")

    while True:
        if args.max_pages and page > args.max_pages:
            print(f"reconcile: stopping at --max-pages={args.max_pages}")
            break
        raw = gh_get_page(args.repo, page)
        if not isinstance(raw, list) or len(raw) == 0:
            break  # past the last page
        # PRs come back on the issues endpoint - exclude them.
        rows = [compact(i, args.repo) for i in raw if "pull_request" not in i]
        (ckpt / f"page-{page:04d}.jsonl").write_text(
            "".join(json.dumps(r, separators=(",", ":")) + "\n" for r in rows),
            encoding="utf-8",
        )
        print(f"reconcile: page {page} -> {len(rows)} issues (raw {len(raw)})", flush=True)
        page += 1

    # combine page checkpoints in order
    lines = []
    for pf in sorted(ckpt.glob("page-*.jsonl")):
        lines.extend(l for l in pf.read_text(encoding="utf-8").splitlines() if l.strip())
    count = len(lines)
    partial = bool(args.max_pages)

    # validate BEFORE swap - a malformed / degenerate / body-bearing pull must NEVER
    # replace the last-good mirror. Parse EVERY line; enforce the compact contract.
    # A DUPLICATE issue number is NOT corruption: paginating a live repo can surface the
    # SAME issue on two pages (it was updated mid-pull), so we DEDUPE (keep the latest line,
    # first-seen order) rather than reject the whole reconcile. `sort=created&direction=asc`
    # keeps pages stable to minimise this, but the dedupe is the robust guarantee.
    deduped = {}
    order = []
    for ln in lines:
        try:
            rec = json.loads(ln)
        except json.JSONDecodeError as exc:
            print(f"reconcile: VALIDATION FAILED - malformed JSONL line: {exc}", file=sys.stderr)
            return 2
        if len(rec.get("body") or "") > 2 * BODY_EXCERPT:  # must be a BOUNDED excerpt, not a full body
            print("reconcile: VALIDATION FAILED - body excerpt too large (not a compact mirror)", file=sys.stderr)
            return 2
        num = rec.get("number")
        ref = (rec.get("source_ref") or {}).get("ref")
        if num is None or not ref:
            print("reconcile: VALIDATION FAILED - record missing number/source_ref.ref", file=sys.stderr)
            return 2
        if num not in deduped:
            order.append(num)
        deduped[num] = ln  # last occurrence wins (most recent state of that issue)
    dups = len(lines) - len(deduped)
    if dups:
        print(f"reconcile: deduped {dups} pagination-drift duplicate(s)")
    lines = [deduped[n] for n in order]
    count = len(lines)
    if not partial and count < args.min_expected:
        print(
            f"reconcile: VALIDATION FAILED - {count} issues < min {args.min_expected}; "
            f"keeping last-good mirror (re-run with --resume)",
            file=sys.stderr,
        )
        return 2
    if count > args.max_expected:
        print(f"reconcile: VALIDATION FAILED - {count} > max {args.max_expected}", file=sys.stderr)
        return 2

    # A PARTIAL run (--max-pages) MUST NOT replace the live mirror unless explicitly
    # allowed - it writes a *.partial.* smoke artifact instead, and the consumer rejects
    # any mirror whose state carries `partial: true`.
    if partial and not args.allow_partial_swap:
        model_out = mdir / "open_issues.compact.partial.jsonl"
        state_out = mdir / "reconcile_state.partial.json"
        print("reconcile: PARTIAL run -> writing smoke artifact (NOT the live mirror)")
    else:
        model_out, state_out = model, state

    # atomic swap
    tmp = model_out.parent / (model_out.name + ".tmp")
    tmp.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
    os.replace(tmp, model_out)

    now = time.time()
    state_out.write_text(
        json.dumps(
            {
                "model_version": MODEL_VERSION,
                "source_repo": args.repo,
                "count": count,
                "fresh_as_of_epoch": int(now),
                "fresh_as_of": datetime.now(timezone.utc).isoformat(),
                "reconcile_seconds": round(now - started, 1),
                "partial": partial,
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    # success: clear the checkpoint
    for pf in ckpt.glob("page-*.jsonl"):
        pf.unlink()

    print(
        f"reconcile: OK - {count} issues -> {model_out} in {round(now - started, 1)}s "
        f"(source {args.repo})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
