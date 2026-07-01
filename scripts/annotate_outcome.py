#!/usr/bin/env python3
"""annotate_outcome.py — attach a durable finding/annotation to a candidate's outcome.

Appends a §5 outcome record (latest-wins by dedup_key) carrying a human/agent `note` — and
optionally an updated `reason`/`state` — so a review finding (e.g. "already fixed upstream by
#18499; bad propose candidate") is TRACKED in the harness's durable outcomes channel and shown
on the dashboard + TUI. Read-modify-append: the candidate's existing score/type/source_ref/…
are preserved; only note/reason/state are overlaid.

Usage:
  python3 scripts/annotate_outcome.py --issue 16205 --reason already_fixed_upstream \
      --note "Fixed upstream by openai/codex#18499; local draft fix/16205-… (defense-in-depth)."
  python3 scripts/annotate_outcome.py --dedup "codex-triage:dup:openai/codex#16205" --note "…"

Stop `supervise` before annotating, or the loop may append a fresh record and supersede this one.
Env: FKST_DURABLE_ROOT (default ./.fkst/durable).
"""
import argparse
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUR = os.environ.get("FKST_DURABLE_ROOT") or os.path.join(REPO, ".fkst", "durable")
PATH = os.path.join(DUR, "codex-saga", "outcomes.jsonl")

# Field order mirrors core/outcomes_store.lua encode_outcome_json (schema stability).
FIELDS = [
    "source_ref", "dedup_key", "picked_score", "area_labels", "type", "exemplars_used",
    "engagement_reaction", "ci", "review_comment_themes", "disposition", "advocate_verdict",
    "advocate_reason", "consensus_angles", "deliberation_count", "state", "reason",
    "root_cause", "note",
]


def latest_record(dedup, issue):
    found = None
    if not os.path.exists(PATH):
        return None
    with open(PATH) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            k = d.get("dedup_key") or ""
            if dedup and k == dedup:
                found = d
            elif issue and k.endswith("#" + str(issue)):
                found = d
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--issue", help="foreign issue number, matched at the end of dedup_key")
    ap.add_argument("--dedup", help="full dedup_key")
    ap.add_argument("--note", required=True, help="the finding/annotation text")
    ap.add_argument("--reason", help="overlay reason (e.g. already_fixed_upstream)")
    ap.add_argument("--state", help="overlay saga state (e.g. needs_info)")
    args = ap.parse_args()
    if not args.issue and not args.dedup:
        ap.error("give --issue or --dedup")

    if subprocess.run(["pgrep", "-f", "fkst-framework supervise"],
                      capture_output=True).returncode == 0:
        print("refusing: supervise is running — stop it first, or it may supersede this note.",
              file=sys.stderr)
        sys.exit(1)

    rec = latest_record(args.dedup, args.issue)
    if rec is None:
        print(f"no existing outcome for {args.dedup or ('#' + args.issue)} — "
              "annotate a candidate the loop has already recorded.", file=sys.stderr)
        sys.exit(2)

    rec["note"] = args.note
    if args.reason:
        rec["reason"] = args.reason
    if args.state:
        rec["state"] = args.state

    ordered = {k: rec.get(k) for k in FIELDS if k in rec or k in ("note",)}
    # keep any extra keys the record already had, appended after the known schema
    for k, v in rec.items():
        if k not in ordered:
            ordered[k] = v

    os.makedirs(os.path.dirname(PATH), exist_ok=True)
    with open(PATH, "a") as f:
        f.write(json.dumps(ordered, separators=(",", ":")) + "\n")
    print(f"annotated {rec.get('dedup_key')}: reason={rec.get('reason')} note={args.note[:60]}…")


if __name__ == "__main__":
    main()
