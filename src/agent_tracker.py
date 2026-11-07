#!/usr/bin/env python3
"""agent-tracker: the only writer of the two facts about a Claude session that
nobody else keeps and a crash would lose - where it runs, and its lifecycle -
plus the account's freshest quota reading in one small file. DESIGN.md §4-§6;
the file formats are the contract of FOR_READERS.md §4.

  agent-tracker tick [--agent claude|codex]
      stdin: the statusline JSON. Copies it to stdout byte for byte (first,
      then closes stdout, so the display chained after it starts at once),
      then: data/sessions/<uuid>/last_seen.json (rewritten whole, temp +
      rename, only if a field other than ts/dt changed or ts is >= 60 s old),
      the usage recording (statusline_usage.store: the gates' databases), and
      data/claude/quota_latest.json from the payload's rate_limits when that
      reading is fresher. Never fails: any error -> logs/tick-errors.log, exit 0.
  agent-tracker hook start|end [--agent claude|codex]
      stdin: the SessionStart / SessionEnd hook JSON. Appends one line (< 512
      bytes, one write) to data/sessions/<uuid>/lifecycle.jsonl. Prints
      nothing (SessionStart's stdout would enter Claude's context); exit 0.
  agent-tracker now [--pane %id] [--uuid U] [--json]
      the open Claude sessions of the current boot (last lifecycle event a
      start, its pid alive with the same start time): pane (resolved now by
      pane_id through tmux), folder, status (Claude Code's live
      sessions/<pid>.json), last prompt (the end of the transcript), last seen.
  agent-tracker check
      one line per problem, exit 1 if any; "all good", exit 0, otherwise.
  agent-tracker last-seen-age [--agent claude]
      for the quota jobs: seconds since the newest last_seen.json of that
      agent (a statusline on screen here), 999999999 when there is none.

Paths: AGENT_TRACKER_HOME (default ~/opt/agent-tracker; usage_db.RUNTIME_DIR),
CLAUDE_CONFIG_DIR (default ~/.claude), TMUX_TMPDIR (tmux's own), and
AGENT_TRACKER_BOOT_TS (tests: the current boot's start, to simulate a reboot).

Speed (tick runs every 10 s per open Claude session): no subprocess but one
`tmux display` per tick; the process tree and the boot time come from the
kernel through ctypes (macOS libproc / sysctl) or /proc (Linux), with `ps`
only as a fallback. Measured: tests/test_agent_tracker.sh, section "tick is fast".
"""
import json
import os
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))   # run through ~/.local/bin/agent-tracker (a link)
import usage_db  # noqa: E402

# This machine's name, written here by install.sh (skill machine-name), so a tick needs no scutil call.
MACHINE_NAME = "__MACHINE_NAME__"

HOME = usage_db.RUNTIME_DIR
SESSIONS_DIR = HOME / "data" / "sessions"
LOGS_DIR = HOME / "logs"
CLAUDE_DIR = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
UUID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}")   # a folder name: no "/", no ".."
REWRITE_AFTER_S = 60       # last_seen.json: rewritten at least this often while ticking
STALE_AFTER_S = 120        # check: a last_seen.json older than this is not being written
TAIL_BYTES = 262144        # the end of a transcript read for the last prompt
NEVER = 999999999          # last-seen-age when nothing was ever seen


# ---------------------------------------------------------------- small helpers

def iso(ts) -> str | None:
    return None if ts is None else usage_db.iso(int(ts))


def machine() -> str | None:
    try:
        return usage_db.machine_name()
    except (OSError, RuntimeError):
        return None


def read_json(path: Path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def write_json_atomic(path: Path, d_obj: dict) -> None:
    """The whole file, through a temp file + rename: a reader sees the old or
    the new file, never half of one. The temp name carries our pid, so two
    writers at once never share one."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(d_obj, separators=(",", ":")) + "\n")
    tmp.replace(path)


def log_error(name: str, stage: str) -> None:
    """Appends a failure, with its traceback, to logs/<name>-errors.log, which
    is started over once past 256 KB: it cannot grow without bound."""
    try:
        import traceback
        LOGS_DIR.mkdir(parents=True, exist_ok=True)
        path = LOGS_DIR / f"{name}-errors.log"
        mode = "w" if path.exists() and path.stat().st_size > 262144 else "a"
        with open(path, mode) as f:   # a log, not a data file
            f.write(f"{usage_db.iso(int(time.time()))} {stage} failed\n{traceback.format_exc()}\n")
    except Exception:
        pass


# ---------------------------------------------------------------- processes and boot

def boot_ts() -> int | None:
    """The current boot's start (epoch s): AGENT_TRACKER_BOOT_TS (tests), else
    the kernel's (macOS sysctl kern.boottime, Linux /proc/stat btime)."""
    if os.environ.get("AGENT_TRACKER_BOOT_TS"):
        return int(os.environ["AGENT_TRACKER_BOOT_TS"])
    return kernel_boot_ts()


def kernel_boot_ts() -> int | None:
    """The real boot's start, whatever AGENT_TRACKER_BOOT_TS says."""
    if sys.platform == "darwin":
        try:
            import ctypes
            libc = ctypes.CDLL(None)
            buf = (ctypes.c_long * 2)()                     # struct timeval {tv_sec, tv_usec}
            size = ctypes.c_size_t(ctypes.sizeof(buf))
            if libc.sysctlbyname(b"kern.boottime", buf, ctypes.byref(size), None, ctypes.c_size_t(0)) == 0:
                return int(buf[0])
        except (OSError, AttributeError):
            pass
        import subprocess
        out = subprocess.run(["sysctl", "-n", "kern.boottime"], capture_output=True, text=True).stdout
        m = re.search(r"sec = (\d+)", out)
        return int(m.group(1)) if m else None
    try:
        for line in open("/proc/stat"):
            if line.startswith("btime "):
                return int(line.split()[1])
    except OSError:
        pass
    return None


_LIBPROC = None


def proc_info(pid: int) -> tuple[int, int, str] | None:
    """(ppid, start time in epoch s, command name) of a running process, or
    None when there is no such process. macOS: libproc's proc_pidinfo
    (PROC_PIDTBSDINFO, struct proc_bsdinfo: ppid at byte 16, pbi_comm at 48,
    pbi_start_tvsec at 120, 136 bytes in all); Linux: /proc/<pid>/stat;
    elsewhere or on failure: `ps` (LC_ALL=C, so lstart parses)."""
    global _LIBPROC
    if pid is None or pid <= 0:
        return None
    if sys.platform == "darwin":
        try:
            import ctypes
            import struct
            if _LIBPROC is None:
                _LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib")
            buf = ctypes.create_string_buffer(136)
            if _LIBPROC.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(3), ctypes.c_uint64(0), buf, ctypes.c_int(136)) != 136:
                return None
            ppid = struct.unpack_from("I", buf.raw, 16)[0]
            comm = buf.raw[48:64].split(b"\0")[0].decode(errors="replace")
            start = struct.unpack_from("Q", buf.raw, 120)[0]
            return ppid, int(start), comm
        except (OSError, AttributeError):
            pass
    elif os.path.exists("/proc/self/stat"):
        try:
            raw = Path(f"/proc/{pid}/stat").read_text()
        except OSError:
            return None
        comm = raw[raw.index("(") + 1:raw.rindex(")")]
        l_fields = raw[raw.rindex(")") + 2:].split()       # field 3 (state) onwards
        ppid, start_ticks = int(l_fields[1]), int(l_fields[19])
        return ppid, int(kernel_boot_ts() + start_ticks / os.sysconf("SC_CLK_TCK")), comm
    import subprocess
    out = subprocess.run(["ps", "-o", "ppid=,lstart=,comm=", "-p", str(pid)], capture_output=True, text=True,
                         env={**os.environ, "LC_ALL": "C"}).stdout.strip()
    if not out:
        return None
    l_parts = out.split()
    start = time.mktime(time.strptime(" ".join(l_parts[1:6]), "%a %b %d %H:%M:%S %Y"))
    return int(l_parts[0]), int(start), os.path.basename(" ".join(l_parts[6:]))


def alive(pid, pid_start) -> bool:
    """The process runs and is the same one: a reused pid has another start time."""
    info = proc_info(pid) if isinstance(pid, int) else None
    return info is not None and pid_start is not None and abs(info[1] - int(pid_start)) <= 1


def proc_argv(pid: int) -> list[str] | None:
    """A process's arguments, argv[0] first, exactly as it was started (no
    splitting on spaces), or None when there is no such process or it is not
    readable. macOS: sysctl KERN_PROCARGS2; Linux: /proc/<pid>/cmdline; else
    `ps` (split on spaces)."""
    try:
        if sys.platform == "darwin":
            import ctypes
            import struct
            libc = ctypes.CDLL(None)
            mib = (ctypes.c_int * 3)(1, 49, pid)             # CTL_KERN, KERN_PROCARGS2
            size = ctypes.c_size_t(1 << 18)
            buf = ctypes.create_string_buffer(size.value)
            if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, ctypes.c_size_t(0)) != 0:
                return None
            argc = struct.unpack_from("i", buf.raw, 0)[0]
            raw = buf.raw[4:size.value]                       # after argc: exec path, NULs, argv[0], ...
            _, _, rest = raw.partition(b"\0")
            return [a.decode(errors="replace") for a in rest.lstrip(b"\0").split(b"\0")[:argc]]
        if os.path.exists("/proc/self/cmdline"):
            return [a.decode(errors="replace") for a in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")[:-1]]
    except Exception:                                     # no such process, or not allowed
        return None
    import subprocess
    return subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout.split() or None


def proc_name(pid: int) -> str | None:
    """The name a process was started as: the basename of its argv[0]
    ("claude", "codex"). Not the kernel's command name, which is the real
    binary's (Claude Code's is its version, "2.1.319": verified 2026-11-07)."""
    l_argv = proc_argv(pid)
    return (os.path.basename(l_argv[0]) or None) if l_argv else None


def is_conversation(d_live: dict | None, pid: int | None = None) -> bool:
    """Whether a Claude process is a conversation someone opened in a terminal:
    not `claude -p` and not an SDK process (entrypoint sdk-cli: the Remote
    Control bridge, `claude --print --sdk-url ...`, whose live file says
    kind "interactive": verified 2026-11-07). Claude Code's live file
    (sessions/<pid>.json) says; without it (at SessionStart it may not be
    written yet), the command line: -p or --print. Nothing to go by: yes."""
    if isinstance(d_live, dict) and d_live:
        return d_live.get("kind", "interactive") == "interactive" and d_live.get("entrypoint", "cli") == "cli"
    l_argv = proc_argv(pid) if isinstance(pid, int) else None
    return not (l_argv and {"-p", "--print"} & set(l_argv[1:]))


def agent_pid(agent: str) -> tuple[int | None, int | None]:
    """(pid, start) of the agent process this one runs under: walking up from
    our parent, the first pid that has $CLAUDE_CONFIG_DIR/sessions/<pid>.json
    (Claude Code's own live file), else the nearest process started as
    `claude` / `codex` (Codex has no such file; a Claude session's file may
    not be written yet at SessionStart). (None, None) when there is neither."""
    pid, l_chain = os.getppid(), []
    for _ in range(32):                                   # a deeper tree is not ours
        info = proc_info(pid)
        if info is None:
            break
        ppid, start, _ = info
        if agent == "claude" and (CLAUDE_DIR / "sessions" / f"{pid}.json").exists():
            return pid, start
        l_chain.append((pid, start))
        if ppid <= 1 or ppid == pid:
            break
        pid = ppid
    for pid, start in l_chain:                            # only now the names: rarely needed
        if proc_name(pid) == agent:
            return pid, start
    return None, None


def is_codex_daemon(pid) -> bool:
    """Whether pid is Codex's shared background process (`codex app-server`,
    the parent of every Codex hook since Codex 0.167: verified 2026-11-07).
    One serves every Codex window and keeps the $TMUX_PANE of the pane the
    first one was opened in, so its pid and pane say nothing about the
    session a hook is for; that window's own status line does (tick)."""
    l_argv = proc_argv(pid) if isinstance(pid, int) else None
    return bool(l_argv) and len(l_argv) > 1 and l_argv[1] == "app-server"


# ---------------------------------------------------------------- tmux

def tmux(*l_args: str) -> str | None:
    """tmux's output, or None when tmux is missing, has no server or fails.
    The server is the one of $TMUX (inside a pane) or of $TMUX_TMPDIR."""
    import subprocess
    try:
        res = subprocess.run(["tmux", *l_args], capture_output=True, text=True, timeout=2)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return res.stdout if res.returncode == 0 else None


# window_name last: the only field that may hold a tab.
PANE_FORMAT = "\t".join(["#{session_name}", "#{window_id}", "#{window_index}", "#{pane_id}", "#{pane_index}",
                         "#{window_layout}", "#{window_name}"])
PANE_KEYS = ("tmux_session", "window_id", "window_index", "pane_id", "pane_index", "window_layout", "window_name")


def pane_fields() -> dict:
    """The tmux fields of last_seen.json for the pane in $TMUX_PANE; all None outside tmux."""
    d_out = dict.fromkeys(PANE_KEYS + ("pane",))
    pane_id = os.environ.get("TMUX_PANE")
    out = tmux("display", "-p", "-t", pane_id, PANE_FORMAT) if pane_id else None
    if out:
        l_values = out.rstrip("\n").split("\t", len(PANE_KEYS) - 1)
        if len(l_values) == len(PANE_KEYS):
            d_out.update(zip(PANE_KEYS, l_values))
            for key in ("window_index", "pane_index"):
                d_out[key] = int(d_out[key]) if str(d_out[key]).isdigit() else None
            d_out["pane"] = f"{d_out['tmux_session']}:{d_out['window_index']}.{d_out['pane_index']}"
    return d_out


def panes_now() -> dict:
    """pane_id -> {"tmux_session", "window_index", "pane_index", "pane"}, for every pane of the tmux server now."""
    out = tmux("list-panes", "-a", "-F", "#{pane_id}\t#{window_index}\t#{pane_index}\t#{session_name}") or ""
    d_out = {}
    for line in out.splitlines():
        l_values = line.split("\t", 3)
        if len(l_values) == 4 and l_values[1].isdigit() and l_values[2].isdigit():
            pane_id, window_index, pane_index, session = l_values
            d_out[pane_id] = {"tmux_session": session, "window_index": int(window_index),
                              "pane_index": int(pane_index), "pane": f"{session}:{window_index}.{pane_index}"}
    return d_out


# ---------------------------------------------------------------- quota_latest.json

def quota_path(agent: str) -> Path:
    return HOME / "data" / agent / "quota_latest.json"


def offer_quota(agent: str, ts: int, source: str, machine_name, d_five, d_week) -> bool:
    """Writes data/<agent>/quota_latest.json when this reading is fresher
    (larger ts) than the one there, or as old with other values; returns
    whether it did. A tie with other values is a later reading: a Claude
    session can report a new percent under the same ts (its last answer's
    time), 85 times in 2 days on 2026-11-07 (31% kept, 32% refused). Windows are
    {"used_percentage", "resets_at" (epoch s)} or None, the shape of Claude
    Code's statusline `rate_limits`. One writer at a time (flock on the
    folder), so an older reading never replaces a newer one."""
    import fcntl
    path = quota_path(agent)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        d_old = read_json(path)
        if isinstance(d_old, dict) and isinstance(d_old.get("ts"), int) and (
                d_old["ts"] > ts or d_old["ts"] == ts and (d_old.get("five_hour"), d_old.get("seven_day")) == (d_five, d_week)):
            return False
        write_json_atomic(path, {"ts": int(ts), "dt": iso(ts), "source": source, "machine": machine_name,
                                 "five_hour": d_five, "seven_day": d_week})
        return True
    finally:
        os.close(fd)


def _window(pct, resets_at) -> dict | None:
    """One window in quota_latest.json's shape; whole percents as ints."""
    if pct is None:
        return None
    if isinstance(pct, float) and pct.is_integer():
        pct = int(pct)
    import ingest_account_quota
    return {"used_percentage": pct, "resets_at": ingest_account_quota._epoch(resets_at)}


def offer_quota_from_payload(d_payload: dict, when: int) -> bool:
    """tick: the statusline's rate_limits, dated `when` (statusline_usage.store's date)."""
    d_limits = d_payload.get("rate_limits") or {}
    l_windows = [_window((d_limits.get(k) or {}).get("used_percentage"), (d_limits.get(k) or {}).get("resets_at"))
                 for k in ("five_hour", "seven_day")]
    return offer_quota("claude", when, "statusline", machine(), *l_windows)


def offer_quota_from_db(agent: str) -> bool:
    """The quota pollers, after each run: the newest reading of
    data/<agent>/account_quotas.db (any source, any machine: the poller's
    own, or one the sync brought), unchanged - no reset rule here, readers
    apply it (FOR_READERS.md rule 8)."""
    import sqlite3
    db = usage_db.open_account(agent, readonly=True)
    if db is None:
        return False
    db.row_factory = sqlite3.Row
    row = db.execute("SELECT * FROM account_quotas WHERE five_hour_pct IS NOT NULL OR seven_day_pct IS NOT NULL "
                     "ORDER BY ts DESC, rowid DESC LIMIT 1").fetchone()
    if row is None:
        return False
    return offer_quota(agent, row["ts"], "statusline" if row["source"].endswith("_statusline") else "poller",
                       row["machine"] if "machine" in row.keys() else None,
                       _window(row["five_hour_pct"], row["five_hour_resets_ts"]),
                       _window(row["seven_day_pct"], row["seven_day_resets_ts"]))


# ---------------------------------------------------------------- the session files

def lifecycle_events(folder: Path) -> list:
    """The lines of folder/lifecycle.jsonl, oldest first; a last line without
    its final newline (being written) is left out, so is an unreadable one."""
    try:
        raw = (folder / "lifecycle.jsonl").read_text()
    except OSError:
        return []
    l_events = []
    for line in raw.split("\n")[:-1]:
        try:
            d_event = json.loads(line)
        except ValueError:
            continue
        if isinstance(d_event, dict):
            l_events.append(d_event)
    return l_events


def newest_seen_age(agent: str | None = None, now: float | None = None) -> int:
    """Seconds since the newest last_seen.json (of `agent`, any when None):
    the quota jobs' "a statusline is on screen here". The files' mtime is
    their ts (written at that moment), so only the recent ones are read."""
    now = time.time() if now is None else now
    best = None
    try:
        l_dirs = list(os.scandir(SESSIONS_DIR))
    except OSError:
        return NEVER
    for entry in l_dirs:
        path = Path(entry.path) / "last_seen.json"
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        if best is not None and mtime <= best:
            continue
        d_seen = read_json(path)
        if not isinstance(d_seen, dict) or not isinstance(d_seen.get("ts"), int):
            continue
        if agent and d_seen.get("agent") != agent:
            continue
        best = max(best or 0, d_seen["ts"])
    return NEVER if best is None else max(0, int(now - best))


def write_last_seen(d_payload: dict, agent: str) -> bool:
    """data/sessions/<uuid>/last_seen.json from one statusline payload;
    returns whether it was rewritten (only if a field other than ts/dt
    changed, or the file's ts is REWRITE_AFTER_S old)."""
    uuid = d_payload.get("session_id") or (d_payload.get("thread_id") if agent == "codex" else None)
    if not isinstance(uuid, str) or not UUID_RE.fullmatch(uuid):   # Codex's status line names it thread_id (= its hooks' session_id)
        return False
    now = int(time.time())
    pid, pid_start = agent_pid(agent)
    d_pane = pane_fields()
    d_new = {"ts": now, "dt": iso(now), "agent": agent, "machine": machine(), "boot_ts": boot_ts(),
             "uuid": uuid, "pid": pid, "pid_start": pid_start,
             **{k: d_pane[k] for k in ("tmux_session", "window_id", "window_index", "window_name",
                                       "pane_id", "pane_index", "pane", "window_layout")},
             "cwd": d_payload.get("cwd") or (d_payload.get("workspace") or {}).get("current_dir"),
             "transcript": d_payload.get("transcript_path")}
    path = SESSIONS_DIR / uuid / "last_seen.json"
    d_old = read_json(path)
    # tmux gone (its server killed, 2026-11-07 15:30) but this process still ticks: keep the last known
    # pane, window and layout instead of overwriting them with nulls; they are what a restore needs.
    l_tmux_keys = ("tmux_session", "window_id", "window_index", "window_name", "pane_id", "pane_index", "pane",
                   "window_layout")
    if os.environ.get("TMUX_PANE") and d_new["pane_id"] is None and isinstance(d_old, dict) \
            and d_old.get("pid") == pid and d_old.get("pane_id"):
        d_new.update({k: d_old.get(k) for k in l_tmux_keys})
    if isinstance(d_old, dict) and isinstance(d_old.get("ts"), int) and now - d_old["ts"] < REWRITE_AFTER_S \
            and {k: v for k, v in d_old.items() if k not in ("ts", "dt")} == \
            {k: v for k, v in d_new.items() if k not in ("ts", "dt")}:
        return False
    write_json_atomic(path, d_new)
    return True


def append_lifecycle(event: str, d_hook: dict, agent: str) -> bool:
    """One line in data/sessions/<uuid>/lifecycle.jsonl: one write() of < 512
    bytes on an O_APPEND file, so two hooks at once never mix their lines."""
    uuid = d_hook.get("session_id")
    if not isinstance(uuid, str) or not UUID_RE.fullmatch(uuid):
        return False
    now = int(time.time())
    pid, pid_start = agent_pid(agent)
    via_daemon = agent == "codex" and is_codex_daemon(pid)
    if via_daemon:       # not this session's window: no pid, no pane (its status line writes them in last_seen.json)
        pid = pid_start = None
    if agent == "claude" and pid is not None and \
            not is_conversation(read_json(CLAUDE_DIR / "sessions" / f"{pid}.json"), pid):
        return False     # claude -p or an SDK process: no folder (design/IMPLEMENTATION.md §5)
    if event == "start":
        pane_id = None if via_daemon else os.environ.get("TMUX_PANE") or None
        pane = (tmux("display", "-p", "-t", pane_id, "#{session_name}:#{window_index}.#{pane_index}") or "").strip() \
            if pane_id else ""
        d_line = {"ts": now, "dt": iso(now), "event": "start", "source": d_hook.get("source") or "startup",
                  "agent": agent, "machine": machine(), "boot_ts": boot_ts(), "pid": pid, "pid_start": pid_start,
                  "pane_id": pane_id, "pane": pane or None, "cwd": d_hook.get("cwd") or os.getcwd()}
    else:
        d_line = {"ts": now, "dt": iso(now), "event": "end", "reason": d_hook.get("reason") or "other", "pid": pid}
    line = json.dumps(d_line, separators=(",", ":"))
    while len(line.encode()) >= 512 and d_line.get("cwd"):     # only a very long folder: cut it
        d_line["cwd"] = d_line["cwd"][:len(d_line["cwd"]) - (len(line.encode()) - 500)]
        line = json.dumps(d_line, separators=(",", ":"))
    folder = SESSIONS_DIR / uuid
    folder.mkdir(parents=True, exist_ok=True)
    fd = os.open(folder / "lifecycle.jsonl", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        os.write(fd, (line + "\n").encode())
    finally:
        os.close(fd)
    return True


# ---------------------------------------------------------------- now

def last_prompt(transcript) -> dict | None:
    """The last `user` entry of the transcript's end that is not a tool
    result (nor a meta entry): {"ts", "dt", "text"} (text: its first 80
    characters, on one line), or None."""
    if not transcript:
        return None
    try:
        size = os.path.getsize(transcript)
    except OSError:
        return None
    window = TAIL_BYTES
    while True:   # the end first, then 4x more, up to the whole file: a long tool-only stretch hides the prompt
        try:
            with open(transcript, "rb") as f:
                f.seek(max(0, size - window))
                data = f.read(min(window, size))
        except OSError:
            return None
        d_found = _last_prompt_in(data)
        if d_found or window >= size:
            return d_found
        window *= 4


def _last_prompt_in(data: bytes) -> dict | None:
    """last_prompt's search in one block of transcript lines (a cut first line simply fails to parse)."""
    from datetime import datetime
    for line in reversed(data.splitlines()):
        if b'"user"' not in line:
            continue
        try:
            d_entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(d_entry, dict) or d_entry.get("type") != "user" or d_entry.get("isMeta") \
                or d_entry.get("isCompactSummary"):
            continue
        content = (d_entry.get("message") or {}).get("content")
        if isinstance(content, list):
            if any(isinstance(x, dict) and x.get("type") == "tool_result" for x in content):
                continue
            content = " ".join(x.get("text", "") for x in content if isinstance(x, dict) and x.get("type") == "text")
        if not isinstance(content, str) or content.lstrip().startswith(("<task-notification>", "<system-reminder>")):
            continue
        try:
            ts = int(datetime.fromisoformat(str(d_entry.get("timestamp")).replace("Z", "+00:00")).timestamp())
        except ValueError:
            continue
        return {"ts": ts, "dt": iso(ts), "text": " ".join(content.split())[:80]}
    return None


def open_sessions() -> list:
    """The rows of `now`: every Claude session of the current boot whose last
    lifecycle event is a start and whose process still runs."""
    current_boot = boot_ts()
    l_rows = []
    try:
        l_dirs = sorted(os.scandir(SESSIONS_DIR), key=lambda e: e.name)
    except OSError:
        return []
    d_panes = None
    for entry in l_dirs:
        folder = Path(entry.path)
        l_events = lifecycle_events(folder)
        if not l_events or l_events[-1].get("event") != "start":
            continue
        d_start = l_events[-1]
        if current_boot is None or d_start.get("boot_ts") is None or abs(int(d_start["boot_ts"]) - current_boot) > 2:
            continue
        d_seen = read_json(folder / "last_seen.json") or {}
        pid, pid_start = d_start.get("pid"), d_start.get("pid_start")
        if pid is None and d_start.get("agent") == "codex" and isinstance(d_seen.get("ts"), int) \
                and d_seen["ts"] >= int(d_start.get("ts") or 0):
            pid, pid_start = d_seen.get("pid"), d_seen.get("pid_start")   # started through Codex's background process
        elif d_seen.get("pid") != pid:     # written by an older process of this UUID
            d_seen = {}
        if not alive(pid, pid_start):
            continue
        pane_id = d_seen.get("pane_id") or d_start.get("pane_id")
        if pane_id and d_panes is None:
            d_panes = panes_now()
        d_live = read_json(CLAUDE_DIR / "sessions" / f"{pid}.json") or {}
        if not is_conversation(d_live, pid):
            continue
        transcript = d_seen.get("transcript") or next(iter(CLAUDE_DIR.glob(f"projects/*/{entry.name}.jsonl")), None)
        d_prompt = last_prompt(transcript)
        d_where = (d_panes or {}).get(pane_id) or {}
        # The keys of `now --json`: exactly these, in this order (IMPLEMENTATION.md §5, FOR_READERS.md §4).
        l_rows.append({"uuid": entry.name, "agent": d_start.get("agent") or "claude", "pid": pid,
                       "pid_start": pid_start, "pane_id": pane_id, "pane": d_where.get("pane"),
                       "tmux_session": d_where.get("tmux_session"), "window_index": d_where.get("window_index"),
                       "pane_index": d_where.get("pane_index"),
                       "cwd": d_seen.get("cwd") or d_start.get("cwd"), "status": d_live.get("status"),
                       "transcript": str(transcript) if transcript else None,
                       "last_prompt": {"ts": d_prompt["ts"], "dt": d_prompt["dt"]} if d_prompt else None,
                       "last_seen": {"ts": d_seen["ts"], "dt": d_seen.get("dt")} if isinstance(d_seen.get("ts"), int) else None,
                       "_text": (d_prompt or {}).get("text")})
    return l_rows


def ago(ts, now) -> str:
    if ts is None:
        return "-"
    s = max(0, int(now - ts))
    return f"{s}s" if s < 60 else f"{s // 60}m" if s < 3600 else f"{s // 3600}h{s % 3600 // 60:02d}" if s < 86400 \
        else f"{s // 86400}d"


def cmd_now(pane: str | None, uuid: str | None, as_json: bool) -> int:
    l_rows = [r for r in open_sessions() if (pane is None or r["pane_id"] == pane) and (uuid is None or r["uuid"] == uuid)]
    if as_json:   # the prompt's text is for the table only: not a key of the contract
        print(json.dumps([{k: v for k, v in r.items() if k != "_text"} for r in l_rows], indent=1))
        return 0
    if not l_rows:
        print("no open Claude session")
        return 0
    now = time.time()
    home = str(Path.home())
    l_table = [("PANE", "STATUS", "PROMPT", "SEEN", "UUID", "FOLDER", "LAST PROMPT")] + [
        (r["pane"] or r["pane_id"] or "-", r["status"] or "-", ago((r["last_prompt"] or {}).get("ts"), now),
         ago((r["last_seen"] or {}).get("ts"), now), r["uuid"][:8], (r["cwd"] or "-").replace(home, "~", 1)[-40:],
         r["_text"] or "") for r in l_rows]
    l_width = [max(len(row[i]) for row in l_table) for i in range(6)]
    for row in l_table:
        print("  ".join(cell.ljust(l_width[i]) for i, cell in enumerate(row[:6])) + "  " + row[6])
    return 0


# ---------------------------------------------------------------- check

def cmd_check() -> int:
    """Is every writer writing on this machine? One line per problem."""
    l_problems = []
    now = time.time()
    try:
        l_live = sorted((CLAUDE_DIR / "sessions").glob("*.json"))
    except OSError:
        l_live = []
    for path in l_live:
        d_live = read_json(path)
        if not isinstance(d_live, dict) or not isinstance(d_live.get("pid"), int) or not d_live.get("sessionId"):
            continue
        if proc_info(d_live["pid"]) is None:          # left over from a crash
            continue
        if not is_conversation(d_live):
            continue   # claude -p, or an SDK process (the Remote Control bridge): no folder, no statusline
        uuid, where = d_live["sessionId"], f"pid {d_live['pid']}" + (f", tmux {d_live['tmux']}" if d_live.get("tmux") else "")
        folder = SESSIONS_DIR / uuid
        if not folder.is_dir():
            l_problems.append(f"no folder data/sessions/{uuid}/ for an open Claude session ({where}): "
                              "its hooks and statusline never ran agent-tracker")
            continue
        if not any(e.get("event") == "start" for e in lifecycle_events(folder)):
            l_problems.append(f"no start line in data/sessions/{uuid}/lifecycle.jsonl ({where}): SessionStart hook missing")
        d_seen = read_json(folder / "last_seen.json")
        if not isinstance(d_seen, dict) or not isinstance(d_seen.get("ts"), int):
            l_problems.append(f"no last_seen.json for open Claude session {uuid} ({where}): statusLine not chained")
        elif now - d_seen["ts"] > STALE_AFTER_S:
            l_problems.append(f"last_seen.json of {uuid} is {int(now - d_seen['ts'])} s old ({where}): "
                              "its statusline stopped calling agent-tracker tick")
    d_settings = read_json(CLAUDE_DIR / "settings.json") or {}
    command = ((d_settings.get("statusLine") or {}).get("command") or "").strip()
    if not re.match(r"\(?\s*(\S*/)?agent-tracker tick(\s|$|\))", command):   # plain, or my-setup's "(agent-tracker tick 2>/dev/null || cat) | …"
        l_problems.append(f"statusLine in {CLAUDE_DIR / 'settings.json'} does not start with `agent-tracker tick`: "
                          f"{command or '(none)'}")
    for event, word in (("SessionStart", "start"), ("SessionEnd", "end")):
        l_commands = [h.get("command", "") for g in (d_settings.get("hooks") or {}).get(event) or []
                      for h in (g.get("hooks") or []) if isinstance(h, dict)]
        if not any(f"agent-tracker hook {word}" in c for c in l_commands):
            l_problems.append(f"hook {event} not registered (`agent-tracker hook {word}`): run install.sh")
    for line in l_problems:
        print(line)
    if not l_problems:
        print("all good")
    return 1 if l_problems else 0


# ---------------------------------------------------------------- the commands

def cmd_tick(agent: str) -> int:
    """Never fails, never prints but the payload; see the module docstring."""
    data = b""
    try:
        data = sys.stdin.buffer.read()
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    except Exception:
        log_error("tick", "copying stdin to stdout")
    try:   # stdout closed now (pointed at /dev/null): the display gets its EOF and draws meanwhile
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, 1)
        os.close(devnull)
    except OSError:
        pass
    try:
        d_payload = json.loads(data)
        if not isinstance(d_payload, dict):
            raise ValueError("the payload is not a JSON object")
    except ValueError:
        log_error("tick", "parsing the payload")
        return 0
    try:
        write_last_seen(d_payload, agent)
    except Exception:
        log_error("tick", "writing last_seen.json")
    if agent != "claude":
        return 0
    try:
        import statusline_usage
        when = statusline_usage.store(d_payload)
        if when is not None:
            offer_quota_from_payload(d_payload, when)
    except Exception:
        log_error("tick", "recording the usage")
    return 0


def cmd_hook(event: str, agent: str) -> int:
    try:
        d_hook = json.loads(sys.stdin.buffer.read() or b"{}")
        if isinstance(d_hook, dict):
            append_lifecycle(event, d_hook, agent)
    except Exception:
        log_error("hook", f"hook {event}")
    return 0


def main(l_argv: list[str]) -> int:
    if not MACHINE_NAME.startswith("__"):   # left as is in the repo; filled in when deployed
        os.environ.setdefault("JR_MACHINE_NAME", MACHINE_NAME)
    import argparse
    parser = argparse.ArgumentParser(prog="agent-tracker", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p_tick = sub.add_parser("tick", help="statusline: stdin to stdout, then last_seen.json, usage, quota_latest.json")
    p_hook = sub.add_parser("hook", help="SessionStart / SessionEnd: one line in lifecycle.jsonl")
    p_hook.add_argument("event", choices=("start", "end"))
    for p in (p_tick, p_hook):
        p.add_argument("--agent", choices=("claude", "codex"), default="claude")
    p_now = sub.add_parser("now", help="the open Claude sessions of this boot: pane, folder, status, last prompt")
    p_now.add_argument("--pane", metavar="%ID", help="only the one in this tmux pane")
    p_now.add_argument("--uuid", metavar="U", help="only this Claude session")
    p_now.add_argument("--json", action="store_true", help="a JSON list (FOR_READERS.md §4)")
    sub.add_parser("check", help="is every writer writing here? one line per problem, exit 1 if any")
    p_age = sub.add_parser("last-seen-age", help="for the quota jobs: seconds since the newest last_seen.json")
    p_age.add_argument("--agent", choices=("claude", "codex"))
    args = parser.parse_args(l_argv)
    if args.command == "tick":
        return cmd_tick(args.agent)
    if args.command == "hook":
        return cmd_hook(args.event, args.agent)
    if args.command == "now":
        return cmd_now(args.pane, args.uuid, args.json)
    if args.command == "check":
        return cmd_check()
    print(newest_seen_age(args.agent))
    return 0


if __name__ == "__main__":
    if sys.argv[1:2] in (["tick"], ["hook"]):
        # The writers never fail: whatever happens, exit 0 (argparse's own errors included).
        try:
            main(sys.argv[1:])
        except BaseException:
            log_error(sys.argv[1], "agent-tracker " + " ".join(sys.argv[1:]))
        sys.exit(0)
    sys.exit(main(sys.argv[1:]))
