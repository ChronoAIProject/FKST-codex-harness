#!/usr/bin/env python3
"""FKST codex-harness — live TUI progress tracker.

Reads the SAME durable state the web dashboard reads (docs/DATA-RETRIEVAL.md):
  - `fkst-framework observe --json`  -> live in-flight queue state (when supervise runs)
  - <durable>/codex-saga/outcomes.jsonl  -> terminal outcomes (winners + refused + drops)
  - <durable>/codex-issue-mirror/open_issues.compact.jsonl  -> issue titles

Renders the loop funnel, per-state scoreboard, the current in-flight candidate, and recent
outcomes — refreshing in place. Read-only; never writes durable state.

Usage:
  python3 scripts/track_run.py            # live TUI, refresh every 2s
  python3 scripts/track_run.py --once     # one snapshot (no clear, for logs/CI)
  python3 scripts/track_run.py --interval 1
Env: FKST_DURABLE_ROOT (default ./.fkst/durable), FKST_FRAMEWORK_BIN / BIN (for observe).
"""
import argparse
import json
import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUR = os.environ.get("FKST_DURABLE_ROOT") or os.path.join(REPO, ".fkst", "durable")
BIN = os.environ.get("FKST_FRAMEWORK_BIN") or os.environ.get("BIN")

SAGA_STATES = [
    "triage", "diagnose", "implement", "dossier", "gate", "engage",
    "invite_watch", "open_pr", "track", "outcome_watch",
    "needs_info", "blocked", "refused", "security_routed", "needs_invite", "tracked",
]
TERMINAL = {"needs_info", "blocked", "refused", "security_routed", "needs_invite", "tracked"}

# ANSI
def c(code, s):
    return f"\033[{code}m{s}\033[0m"
BOLD, DIM = "1", "2"
CORAL, TEAL, AMBER, GREY = "38;5;210", "38;5;80", "38;5;179", "38;5;244"


def read_jsonl(path):
    try:
        with open(path, "r") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        yield json.loads(line)
                    except json.JSONDecodeError:
                        continue  # skip a partial/malformed (trailing) line
    except FileNotFoundError:
        return


def latest_outcomes():
    by_key = {}
    for rec in read_jsonl(os.path.join(DUR, "codex-saga", "outcomes.jsonl")):
        k = rec.get("dedup_key")
        if isinstance(k, str):
            by_key[k] = rec
    return by_key


def mirror_titles(numbers):
    """Only titles we need, scanning the mirror once."""
    want, out = set(numbers), {}
    if not want:
        return out
    for row in read_jsonl(os.path.join(DUR, "codex-issue-mirror", "open_issues.compact.jsonl")):
        n = row.get("number")
        if n in want:
            out[n] = row.get("title", "")
            if len(out) == len(want):
                break
    return out


def observe():
    if not BIN or not os.path.exists(os.path.join(DUR, "delivery.redb")):
        return None
    try:
        r = subprocess.run([BIN, "observe", "--durable-root", DUR, "--json"],
                           capture_output=True, text=True, timeout=15)
        if r.returncode == 0 and r.stdout.strip():
            return json.loads(r.stdout)
    except (subprocess.SubprocessError, json.JSONDecodeError, OSError):
        return None
    return None


REFUSED = "refused"

def derive_state(rec):
    if rec.get("state"):
        return rec["state"]
    d = rec.get("disposition") or ""
    if d == "refused_security":
        return "security_routed"
    if d.startswith(REFUSED):
        return "refused"
    if d in ("proposed", "merged", "closed", "ignored"):
        return "tracked"
    if d == "dropped":
        return "needs_info"
    return "diagnose"


def num_from_ref(rec):
    ref = (rec.get("source_ref") or {}).get("ref") or rec.get("dedup_key") or ""
    for tok in ref.replace("#issues/", "#").split("#"):
        if tok.isdigit():
            return int(tok)
    tail = ref.rsplit("#", 1)[-1]
    return int(tail) if tail.isdigit() else None


def snapshot():
    outs = latest_outcomes()
    live = observe()
    nums = [num_from_ref(r) for r in outs.values()]
    titles = mirror_titles([n for n in nums if n])

    rows = []
    for rec in outs.values():
        n = num_from_ref(rec)
        st = derive_state(rec)
        rows.append({
            "num": n, "state": st,
            "title": titles.get(n, rec.get("dedup_key", "")),
            "score": rec.get("picked_score"),
            "reason": rec.get("reason") or rec.get("disposition") or "",
            "verdict": rec.get("advocate_verdict") or "",
            "delib": rec.get("deliberation_count") or 0,
        })

    # in-flight (from observe queues), else nothing
    inflight = []
    queues = []
    if live:
        for e in live.get("entries", []):
            inflight.append({"queue": e.get("queue"), "dept": e.get("dept"),
                             "source": e.get("source"), "attempt": e.get("attempt")})
        for q in live.get("queues", []):
            if q.get("depth"):
                queues.append((q.get("queue"), q.get("depth"), q.get("in_flight", 0)))
    return rows, inflight, queues, live is not None


def render(rows, inflight, queues, live_observe):
    counts = {}
    for r in rows:
        counts[r["state"]] = counts.get(r["state"], 0) + 1
    candidates = len(rows)
    deliberated = sum(1 for r in rows if r["delib"] and r["delib"] > 0)
    refused = sum(1 for r in rows if r["verdict"] == "refuted")
    cleared = sum(1 for r in rows if r["verdict"] == "pass")
    engaged = sum(1 for r in rows if r["state"] in ("engage", "invite_watch", "open_pr", "track", "tracked"))
    tracked = sum(1 for r in rows if r["state"] == "tracked")

    L = []
    mode = c(TEAL, "● supervise/observe LIVE") if live_observe else c(AMBER, "● durable snapshot (no live loop)")
    L.append(c(BOLD, "  MAKE CODEX GREAT AGAIN") + c(GREY, "  · FKST loop tracker · dry-run"))
    L.append(f"  {mode}   durable={c(GREY, DUR)}")
    L.append("")
    # funnel
    def stat(label, v, col=GREY):
        return f"{c(GREY, label)} {c(col, v)}"
    L.append("  " + "   ".join([
        stat("seen", candidates),
        stat("deliberated", deliberated),
        stat("refused", refused, CORAL),
        stat("cleared", cleared, TEAL),
        stat("engaged", engaged, TEAL),
        stat("tracked", tracked, TEAL),
    ]))
    L.append("")
    # scoreboard by state (only non-zero)
    board = [f"{s}={counts[s]}" for s in SAGA_STATES if counts.get(s)]
    L.append("  " + c(GREY, "states: ") + ("  ".join(board) if board else c(DIM, "—")))
    if queues:
        qd = "  ".join(f"{q}:{d}({fl} in-flight)" for q, d, fl in queues)
        L.append("  " + c(GREY, "queues: ") + qd)
    L.append("")
    # in-flight now
    L.append(c(BOLD, "  WORKING NOW"))
    if inflight:
        for e in inflight[:4]:
            L.append(f"    {c(TEAL, '▸')} {e['dept'] or e['queue']}  {c(GREY, e['source'] or '')}  attempt={e['attempt']}")
    else:
        L.append(c(DIM, "    (no in-flight delivery — loop idle or between ticks)"))
    L.append("")
    # recent outcomes
    L.append(c(BOLD, "  OUTCOMES") + c(GREY, f"  ({len(rows)})"))
    def col_for(state):
        if state in ("refused", "security_routed"):
            return CORAL
        if state in ("tracked",):
            return TEAL
        return AMBER if state in TERMINAL else GREY
    for r in sorted(rows, key=lambda x: (x["state"] not in TERMINAL, -(x["score"] or 0)))[:12]:
        num = f"#{r['num']}" if r["num"] else "—"
        sc = ""
        if isinstance(r["score"], (int, float)):
            sv = int(r["score"] * 100) if r["score"] <= 1 else int(r["score"])
            sc = c(GREY, f"{sv:>3}")
        title = (r["title"] or "")[:52]
        why = c(DIM, f"({r['reason']})") if r["reason"] else ""
        L.append(f"    {sc} {c(col_for(r['state']), r['state']):<22} {c(GREY, num):<8} {title} {why}")
    if not rows:
        L.append(c(DIM, "    (no durable outcomes yet — waiting for the loop to produce records)"))
    L.append("")
    L.append(c(GREY, "  FKST_GITHUB_WRITE=<unset> · nothing leaves this machine · Ctrl-C to exit"))
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true", help="print one snapshot and exit")
    ap.add_argument("--interval", type=float, default=2.0)
    args = ap.parse_args()

    if args.once:
        print(render(*snapshot()))
        return
    try:
        while True:
            frame = render(*snapshot())
            sys.stdout.write("\033[2J\033[H")  # clear + home
            sys.stdout.write(frame + "\n")
            sys.stdout.flush()
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print()


if __name__ == "__main__":
    main()
