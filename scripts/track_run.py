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
import glob
import json
import os
import re
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_env_file(path):
    try:
        with open(path, "r") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                if key and key not in os.environ:
                    os.environ[key] = value
    except FileNotFoundError:
        return


load_env_file(os.path.join(REPO, ".fkst", "env"))

DUR = os.environ.get("FKST_DURABLE_ROOT") or os.path.join(REPO, ".fkst", "durable")
DEFAULT_BIN = os.path.abspath(os.path.join(REPO, "..", "FKST-substrate", "target", "debug", "fkst-framework"))
BIN = os.environ.get("FKST_FRAMEWORK_BIN") or os.environ.get("BIN") or DEFAULT_BIN

SAGA_STATES = [
    "triage", "diagnose", "implement", "dossier", "gate", "engage",
    "invite_watch", "open_pr", "track", "outcome_watch",
    "needs_info", "blocked", "refused", "security_routed", "needs_invite", "tracked",
]
TERMINAL = {"needs_info", "blocked", "refused", "security_routed", "needs_invite", "tracked"}
TRACKER_REPO = os.environ.get("FKST_TRACKER_REPO") or "ChronoAIProject/FKST-codex-harness"
ACTIVE_CAP = int(os.environ.get("FKST_TRIAGE_MAX_CANDIDATES") or "0")
WRITE_ENABLED = os.environ.get("FKST_GITHUB_WRITE") == "1"
UPSTREAM_HOLD_UNTIL = os.environ.get("FKST_UPSTREAM_ENGAGE_HOLD_UNTIL") or ""
HELD_UPSTREAM_OPS = {"engage-comment", "open-pr", "cla-comment"}
GH_CACHE = {"ts": 0.0, "issues": [], "error": None}

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


def tracker_issues(max_age=20):
    now = time.time()
    if now - GH_CACHE["ts"] < max_age:
        return GH_CACHE["issues"], GH_CACHE["error"]
    cmd = [
        "gh", "issue", "list",
        "--repo", TRACKER_REPO,
        "--label", "codex-saga:candidate",
        "--state", "open",
        "--limit", "100",
        "--json", "number,title,labels,updatedAt,url",
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        if r.returncode != 0:
            GH_CACHE.update({"ts": now, "issues": [], "error": r.stderr.strip() or "gh issue list failed"})
            return GH_CACHE["issues"], GH_CACHE["error"]
        rows = json.loads(r.stdout or "[]")
        issues = []
        for row in rows:
            labels = [label.get("name") for label in row.get("labels", []) if label.get("name")]
            stage = next((name.replace("codex-saga:", "") for name in labels if re.search(r"\d/6-", name)), "")
            issues.append({
                "number": row.get("number"),
                "title": row.get("title") or "",
                "stage": stage,
                "labels": labels,
                "updatedAt": row.get("updatedAt") or "",
                "url": row.get("url") or "",
            })
        GH_CACHE.update({"ts": now, "issues": issues, "error": None})
        return issues, None
    except (subprocess.SubprocessError, json.JSONDecodeError, OSError) as exc:
        GH_CACHE.update({"ts": now, "issues": [], "error": str(exc)})
        return GH_CACHE["issues"], GH_CACHE["error"]


def running_processes():
    try:
        r = subprocess.run(["ps", "-axo", "pid,etime,stat,command"], capture_output=True, text=True, timeout=10)
    except (subprocess.SubprocessError, OSError):
        return []
    rows = []
    pat = re.compile(r"^\s*(\d+)\s+(\S+)\s+(\S+)\s+(.*)$")
    for line in r.stdout.splitlines():
        if not re.search(r"fkst-framework supervise|fkst-framework run .*codex|codex exec|__codex-worker", line):
            continue
        if "scripts/track_run.py" in line:
            continue
        m = pat.match(line)
        if not m:
            continue
        pid, age, stat, cmd = m.groups()
        if "fkst-framework supervise" in cmd:
            role = "supervisor"
            detail = "live loop"
        elif "__codex-worker" in cmd:
            role = "codex-worker"
            dept = re.search(r"--dept\s+(\S+)", cmd)
            issue = re.search(r"openai_codex_(\d+)", cmd)
            detail = " ".join(x for x in [(dept.group(1) if dept else ""), ("#" + issue.group(1) if issue else "")] if x)
        elif "codex exec" in cmd:
            role = "codex exec"
            issue = re.search(r"openai_codex_(\d+)", cmd)
            detail = "#" + issue.group(1) if issue else "agent running"
        else:
            role = "department"
            dept = re.search(r"departments/([^/]+)/main.lua", cmd)
            issue = re.search(r"openai/codex#(\d+)", cmd)
            detail = " ".join(x for x in [(dept.group(1) if dept else ""), ("#" + issue.group(1) if issue else "")] if x)
        rows.append({"pid": pid, "age": age, "stat": stat, "role": role, "detail": detail})
    return rows


def recent_events(limit=8):
    log_dir = os.path.join(REPO, ".fkst", "runtime", "logs", "framework-child")
    files = sorted(glob.glob(os.path.join(log_dir, "*.log")), key=os.path.getmtime, reverse=True)[:12]
    events = []
    for path in files:
        try:
            with open(path, "r", errors="replace") as f:
                lines = f.readlines()[-80:]
        except OSError:
            continue
        for line in reversed(lines):
            s = line.strip()
            if not s or ("MSG=" not in s and "codex-triage/score_dedup:" not in s):
                continue
            if "framework spawned" in s:
                continue
            ts = re.search(r"TIMESTAMP=([^ ]+)", s)
            msg = re.search(r"MSG=(.*)$", s)
            dept = re.search(r"dept=([^ ]+)", s)
            text = msg.group(1) if msg else s
            if len(text) > 120:
                text = text[:117] + "..."
            events.append({
                "ts": ts.group(1) if ts else "",
                "dept": dept.group(1) if dept else os.path.basename(path).split("-")[0],
                "text": text,
            })
            if len(events) >= limit:
                return events
    return events


def kv_from_text(text):
    out = {}
    for key, value in re.findall(r"([A-Za-z_][A-Za-z0-9_-]*)=([^ ]+)", text):
        out[key] = value
    return out


def dedup_issue(dedup_key):
    if not dedup_key:
        return ""
    m = re.search(r"#(\d+)$", dedup_key)
    return "#" + m.group(1) if m else dedup_key


def publish_label(op):
    labels = {
        "control-issue-create": "tracker claim created",
        "implement-fix": "fix worktree started",
        "fork-branch-push": "fork branch pushed",
        "engaged-label": "tracker marked engaged",
    }
    if op in labels:
        return labels[op]
    if op.startswith("progress-"):
        state = op.replace("progress-", "", 1)
        return "tracker progress -> " + state
    return op


def published_updates(limit=8):
    log_dir = os.path.join(REPO, ".fkst", "runtime", "logs", "framework-child")
    files = sorted(glob.glob(os.path.join(log_dir, "*.log")), key=os.path.getmtime, reverse=True)[:30]
    updates = []
    seen = set()
    for path in files:
        try:
            with open(path, "r", errors="replace") as f:
                lines = f.readlines()
        except OSError:
            continue
        for line in reversed(lines):
            if "OUTBOUND mode=real" not in line:
                continue
            ts = re.search(r"TIMESTAMP=([^ ]+)", line)
            msg = re.search(r"MSG=(.*)$", line.strip())
            text = msg.group(1) if msg else line.strip()
            kv = kv_from_text(text)
            op = kv.get("op", "publish")
            repo = kv.get("repo", "")
            branch = kv.get("branch", "")
            issue = dedup_issue(kv.get("dedup_key", ""))
            subject = issue or branch or repo
            key = (ts.group(1) if ts else "", op, subject)
            if key in seen:
                continue
            seen.add(key)
            detail = publish_label(op)
            if subject:
                detail += " " + subject
            if repo and repo != subject:
                detail += " " + c(GREY, repo)
            if UPSTREAM_HOLD_UNTIL and repo == "openai/codex" and op in HELD_UPSTREAM_OPS:
                detail = c(CORAL, "HELD-UPSTREAM VIOLATION ") + detail
            updates.append({
                "ts": ts.group(1) if ts else "",
                "detail": detail,
            })
            if len(updates) >= limit:
                return updates
    return updates


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


def snapshot(gh_max_age=20):
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
    tracker, tracker_error = tracker_issues(gh_max_age)
    return (
        rows, inflight, queues, live is not None, tracker, tracker_error,
        running_processes(), published_updates(), recent_events(),
    )


def render(rows, inflight, queues, live_observe, tracker, tracker_error, procs, publishes, events):
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
    write_mode = c(TEAL, "LIVE WRITES") if WRITE_ENABLED else c(AMBER, "dry-run")
    cap_status = "unknown"
    cap_col = GREY
    if ACTIVE_CAP > 0:
        if len(tracker) <= ACTIVE_CAP:
            cap_status = f"OK {len(tracker)}/{ACTIVE_CAP}"
            cap_col = TEAL
        else:
            cap_status = f"OVER {len(tracker)}/{ACTIVE_CAP}"
            cap_col = CORAL
    L.append(c(BOLD, "  MAKE CODEX GREAT AGAIN") + c(GREY, "  · FKST supervisor monitor · ") + write_mode)
    L.append(f"  {mode}   durable={c(GREY, DUR)}")
    L.append(f"  {c(GREY, 'goal:')} keep active tracker candidates <= {ACTIVE_CAP or 'unset'}   {c(GREY, 'concurrency:')} {c(cap_col, cap_status)}")
    if UPSTREAM_HOLD_UNTIL:
        L.append(f"  {c(GREY, 'upstream hold:')} {c(AMBER, 'no openai/codex comments or PRs until ' + UPSTREAM_HOLD_UNTIL)}")
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
    L.append(c(BOLD, "  ACTIVE TRACKER CLAIMS"))
    if tracker_error:
        L.append(f"    {c(CORAL, 'tracker error')} {tracker_error}")
    elif tracker:
        shown = ACTIVE_CAP or 6
        for issue in tracker[:shown]:
            stage = issue["stage"] or "candidate"
            title = issue["title"].replace("codex-saga: codex-triage:dup:", "")[:72]
            L.append(f"    {c(TEAL, '▸')} #{issue['number']} {c(GREY, stage):<14} {title}")
        if len(tracker) > shown:
            L.append(c(CORAL, f"    +{len(tracker) - shown} more open candidates"))
    else:
        L.append(c(DIM, "    (no open tracker candidates)"))
    L.append("")
    # in-flight now
    L.append(c(BOLD, "  WORKING NOW"))
    if inflight:
        for e in inflight[:4]:
            L.append(f"    {c(TEAL, '▸')} {e['dept'] or e['queue']}  {c(GREY, e['source'] or '')}  attempt={e['attempt']}")
    else:
        L.append(c(DIM, "    (no in-flight delivery — loop idle or between ticks)"))
    if procs:
        L.append("")
        L.append(c(BOLD, "  LIVE PROCESSES"))
        for p in procs[:8]:
            L.append(f"    {c(GREY, p['pid']):>7} {p['age']:<8} {p['role']:<13} {p['detail']}")
    L.append("")
    L.append(c(BOLD, "  PUBLISHED UPDATES"))
    if publishes:
        for item in publishes:
            L.append(f"    {c(GREY, item['ts'])} {c(TEAL, 'publish')} {item['detail']}")
    else:
        L.append(c(DIM, "    (no recent GitHub publish events)"))
    L.append("")
    L.append(c(BOLD, "  RECENT EVENTS"))
    if events:
        for e in events:
            L.append(f"    {c(GREY, e['ts'])} {e['dept']}: {e['text']}")
    else:
        L.append(c(DIM, "    (no recent framework-child events)"))
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
    write_text = "1 · outward writes enabled" if WRITE_ENABLED else "<unset> · nothing leaves this machine"
    L.append(c(GREY, f"  FKST_GITHUB_WRITE={write_text} · Ctrl-C to exit"))
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true", help="print one snapshot and exit")
    ap.add_argument("--interval", type=float, default=2.0)
    ap.add_argument("--gh-interval", type=float, default=20.0, help="seconds between GitHub tracker refreshes")
    args = ap.parse_args()

    if args.once:
        print(render(*snapshot(0)))
        return
    try:
        while True:
            frame = render(*snapshot(args.gh_interval))
            sys.stdout.write("\033[2J\033[H")  # clear + home
            sys.stdout.write(frame + "\n")
            sys.stdout.flush()
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print()


if __name__ == "__main__":
    main()
