#!/usr/bin/env python3
"""A fake Claude Code process for the integration test (sandbox only).

Behaves like Claude Code toward the tools under test:
  - writes $CLAUDE_CONFIG_DIR/sessions/<own pid>.json (pid, sessionId, cwd, procStart, tmux, status, ...);
  - writes a transcript with one user prompt (2 h ago) if none exists;
  - runs the SessionStart hooks of $CLAUDE_CONFIG_DIR/settings.json with Claude's hook JSON on stdin;
  - every --tick seconds runs the statusLine command with a statusline JSON on stdin;
  - on SIGTERM / SIGINT: runs the SessionEnd hooks (reason "exit"), removes its live file, exits 0;
  - on SIGHUP (its tmux server died): SessionEnd with reason "other", like Claude Code;
  - on SIGKILL (a crash): nothing.
Usage: fake_claude.py [--resume <uuid>] [--uuid <uuid>] [--tick 2] [--out-dir DIR]
Reads:  settings.json, the statusline fixture (FAKE_CLAUDE_FIXTURE)
Writes: sessions/<pid>.json, projects/<folder>/<uuid>.jsonl, <out-dir>/<uuid>.{statusline,hook-out}.txt
"""
import argparse, json, os, signal, subprocess, sys, time, uuid as uuidlib
from datetime import datetime, timezone

p = argparse.ArgumentParser()
p.add_argument("--resume")
p.add_argument("--uuid")
p.add_argument("--tick", type=float, default=2.0)
p.add_argument("--out-dir", default=os.environ.get("FAKE_CLAUDE_OUT", "/tmp"))
a, _ = p.parse_known_args()

CFG = os.environ["CLAUDE_CONFIG_DIR"]
uuid = a.resume or a.uuid or str(uuidlib.uuid4())
source = "resume" if a.resume else "startup"
cwd = os.getcwd()
pid = os.getpid()
now = time.time()


def tmux_fmt(fmt):
    pane = os.environ.get("TMUX_PANE")
    if not pane:
        return None
    r = subprocess.run(["tmux", "display", "-p", "-t", pane, fmt], capture_output=True, text=True)
    return r.stdout.strip() or None


proc_start = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True,
                            env={**os.environ, "LC_ALL": "C", "TZ": "UTC"}).stdout.strip()
live = os.path.join(CFG, "sessions", f"{pid}.json")
os.makedirs(os.path.dirname(live), exist_ok=True)


def write_live(status):
    d = {"pid": pid, "sessionId": uuid, "cwd": cwd, "startedAt": int(now * 1000), "procStart": proc_start,
         "kind": "interactive", "entrypoint": "cli", "status": status,
         "updatedAt": int(time.time() * 1000), "statusUpdatedAt": int(time.time() * 1000)}
    t = tmux_fmt("#{session_name}:#{window_id}.#{pane_id}")
    if t:
        d["tmux"] = t
    with open(live + ".tmp", "w") as f:
        json.dump(d, f)
    os.replace(live + ".tmp", live)


folder = "-" + cwd.strip("/").replace("/", "-").replace(".", "-")
transcript = os.path.join(CFG, "projects", folder, f"{uuid}.jsonl")
if not os.path.exists(transcript):
    os.makedirs(os.path.dirname(transcript), exist_ok=True)
    t0 = datetime.fromtimestamp(now - 7200, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    with open(transcript, "w") as f:
        f.write(json.dumps({"type": "user", "timestamp": t0, "sessionId": uuid, "cwd": cwd,
                            "message": {"role": "user", "content": f"hello from {uuid[:8]}"}}, separators=(",", ":")) + "\n")
        f.write(json.dumps({"type": "assistant", "timestamp": t0, "sessionId": uuid,
                            "message": {"role": "assistant", "content": [{"type": "text", "text": "hi"}]}}, separators=(",", ":")) + "\n")


def settings():
    try:
        return json.load(open(os.path.join(CFG, "settings.json")))
    except Exception:
        return {}


def run_hooks(event, extra):
    out = os.path.join(a.out_dir, f"{uuid}.hook-out.txt")
    payload = json.dumps({"session_id": uuid, "transcript_path": transcript, "cwd": cwd,
                          "hook_event_name": event, **extra})
    for group in settings().get("hooks", {}).get(event, []):
        for h in group.get("hooks", []):
            r = subprocess.run(["sh", "-c", h["command"]], input=payload, capture_output=True, text=True, timeout=30)
            with open(out, "a") as f:
                f.write(f"[{event}] {h['command'][:80]} -> rc={r.returncode} stdout={r.stdout!r}\n")


def tick():
    cmd = (settings().get("statusLine") or {}).get("command")
    if not cmd:
        return
    d = json.load(open(os.environ["FAKE_CLAUDE_FIXTURE"]))
    d.update({"session_id": uuid, "cwd": cwd, "transcript_path": transcript})
    d.setdefault("workspace", {})["current_dir"] = cwd
    reset = int(time.time()) + 3600
    d["rate_limits"] = {"five_hour": {"used_percentage": 42, "resets_at": reset},
                        "seven_day": {"used_percentage": 18, "resets_at": reset + 86400}}
    r = subprocess.run(["sh", "-c", cmd], input=json.dumps(d), capture_output=True, text=True, timeout=10)
    with open(os.path.join(a.out_dir, f"{uuid}.statusline.txt"), "w") as f:
        f.write(r.stdout)


def on_term(signum, frame):
    run_hooks("SessionEnd", {"reason": "exit"})
    try:
        os.remove(live)
    except FileNotFoundError:
        pass
    sys.exit(0)


def on_hup(signum, frame):
    """The tmux server died under it (2026-11-07 15:30): Claude Code logs a SessionEnd with reason "other"."""
    run_hooks("SessionEnd", {"reason": "other"})
    try:
        os.remove(live)
    except FileNotFoundError:
        pass
    sys.exit(0)


signal.signal(signal.SIGTERM, on_term)
signal.signal(signal.SIGINT, on_term)
signal.signal(signal.SIGHUP, on_hup)
write_live("idle")
run_hooks("SessionStart", {"source": source})
sys.stdout.write(f"\x1b[?1049h[fake claude {uuid[:8]}]\n")
sys.stdout.flush()
while True:
    tick()
    time.sleep(a.tick)
