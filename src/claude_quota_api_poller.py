#!/usr/bin/env python3
"""Collector: samples Anthropic's quota API (GET /api/oauth/usage) on a timer,
because that side has no history - a missed reading is permanently lost.
Hands one row per poll to ingest_account_quota.py, which stores it in
data/claude/account_quotas.db: the full raw response, unfiltered, plus its
HTTP response headers - or, when the reading can't be taken, an `error`
object saying which stage failed and why (the poll_errors table). A missing
reading is itself data (roughly 11% of rows historically), and "the token
expired" and "the wifi dropped" need very different responses.

Token usage is deliberately NOT logged here. It's fully recomputable at
analysis time from the transcripts Claude Code itself already writes under
~/.claude/projects/ (transcript_reader.py reads them) - logging it here too
would just be storing a copy of data that already durably exists elsewhere
on disk (cleanupPeriodDays=365 on this machine, so "durably" means about a
year). Only log what can't be recomputed after the fact.

When to poll is decided by its job-runner entrypoint claude-quota.sh
(deployed to ~/opt/agent-tracker/, run every 60 s by its trigger),
which passes --if-older-than: this poller skips (exit 10) while the
account's newest reading, any source, any machine, is younger than that
(doc/design.md §3.4). A 429 waits out its Retry-After on this
machine only - 429s are counted per login token, i.e. per machine
(doc/upstream.md §3.5) - (exit 75, "retry-after N" ending the last
line). One start = at most one attempt.

The MacBook also runs the 2-min sync of the quota readings with the central, the NAS
(--sync-with=babisnas-tailscale --sync-every=110; the VM H-Frank-1 until 2026-11; the central cannot reach the Mac, so the
Mac does both directions, doc/design.md §3.3), before deciding: one
ssh call runs the central's gate (ingest_account_quota.py --sync-from), which
stores the Mac's own new readings and answers with its own. Only a
machine's own readings travel (`machine`); the two watermarks (the last
rowid sent from here, the last asked from the central) are in
state/sync/claude_quotas.json and advance only once both sides stored
everything. The VM unreachable: the sync waits for the next run and the
summary says so; it becomes a failure (exit 1) once the last successful
sync is older than SYNC_STALE_S.

Several accounts (2026-11-19, claude_accounts.py): every Claude account logged in on this machine is polled with its
own token, its own freshness (`--if-older-than` is per account) and its own 429 wait (state/sync/claude_quota_wait.json).
The exit codes follow the main account (a), what the job and its dashboard mean; another account's failure (its login
not used for 8 h reads 401) is in the summary line, never a failed run. One start = at most one attempt per account.

After every run, each account's newest reading (any source, any machine) is
offered to its file (offer_latest): the main account's data/claude/quota_latest.json,
the one file the statusline display reads, another's quota_latest.<name>.json.

Exit codes: 0 a reading, its summary last ("5h 42% · 7d 18%"); 10 fresh
enough, no poll; 75 a 429; 1 any other failure (401, network..., or a
sync failing for too long). Every attempt is stored, reading or failure.

Note this poller's own `source: "claude_api"` rows are a fallback path now, not
the primary one: statusline_payload_reader.py stores a free
`source: "claude_statusline"` reading on every real message, riding
Claude Code's own in-memory rate_limits state - no network call, never
rate-limited. This poller still matters for the gap that push path can't
cover: a session that hasn't sent its first message yet, or a stretch with
no statusline rendering anywhere on the machine at all. Both sources share
data/claude/account_quotas.db (Codex has its own - see
codex_quota_api_poller.py).
"""
import json
import subprocess
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

import claude_accounts
import ingest_account_quota
import usage_db

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
KEYCHAIN_SERVICE = "Claude Code-credentials"
# Where Claude Code keeps the same credential blob on Linux (no Keychain).
CREDENTIALS_FILE = Path.home() / ".claude" / ".credentials.json"

# The central's account gate, run over ssh (a non-login shell: python3 is
# /usr/bin/python3 on the NAS, as for push_to_central.py).
SYNC_COMMAND = "python3 ~/opt/agent-tracker/src/ingest_account_quota.py --agent claude --sync-from={me} --after={after}"
SYNC_STATE = usage_db.RUNTIME_DIR / "state" / "sync" / "claude_quotas.json"
SYNC_TIMEOUT_S = 30
SYNC_STALE_S = 1800  # a sync failing longer than this fails the job
# Per account: until when its 429 Retry-After keeps it from being polled {name: epoch} (2026-11-19: several accounts).
WAIT_STATE = usage_db.RUNTIME_DIR / "state" / "sync" / "claude_quota_wait.json"

# Response headers worth keeping - request-id lets a specific reading be
# cross-referenced/reported to Anthropic support if a number ever looks
# wrong; date is the server's own clock, useful to sanity-check local
# clock skew; org/workspace id distinguish readings if this ever runs
# under more than one account.
HEADERS_TO_KEEP = (
    "date", "request-id", "anthropic-organization-id",
    "anthropic-workspace-id", "server-timing",
)


def fetch_token(config_dir: str | None = None, is_main: bool = True) -> tuple[str | None, dict | None]:
    """Claude Code itself writes the OAuth token on login: in the macOS
    Keychain under this exact service name, or on Linux in
    ~/.claude/.credentials.json (same JSON) - this is the only place on the
    machine reading it for quota purposes (see the module docstring).
    Returns (token, d_error); exactly one is non-None. `config_dir`/`is_main`: the account whose login to read
    (default: the main account); another account's login is in its own Keychain item / its folder's .credentials.json."""
    try:
        if sys.platform == "darwin":
            text = subprocess.run(
                ["security", "find-generic-password", "-s", claude_accounts.service_name(config_dir or "", is_main), "-w"],
                capture_output=True, text=True, timeout=5, check=True,
            ).stdout
        else:
            text = (CREDENTIALS_FILE if is_main or not config_dir else claude_accounts.credentials_file(config_dir)).read_text()
        d_creds = json.loads(text)
        token = d_creds.get("claudeAiOauth", {}).get("accessToken")
        if not token:
            return None, {"stage": "keychain", "type": "MissingAccessToken"}
        return token, None
    except Exception as exc:
        # Type only, never str(exc): this stage handles the credential blob,
        # and an exception message here could echo part of it into the log.
        # The type alone is enough to tell "not logged in" (CalledProcessError)
        # from "Keychain locked/slow" (TimeoutExpired) from "format changed"
        # (JSONDecodeError).
        return None, {"stage": "keychain", "type": type(exc).__name__}


def fetch_usage(token: str) -> tuple[dict | None, dict | None, dict | None]:
    """Returns (body, headers, d_error); d_error is None on success."""
    req = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            # Everything below matches what the real `claude` binary's own
            # fetchUtilization() sends to this same endpoint (recovered by
            # decompiling ~/.local/share/claude/versions/*, 2026-08-30) -
            # urllib's bare defaults (Python-urllib/x.y UA, no Accept, no
            # anthropic-version) fingerprint this as a raw script hitting an
            # internal OAuth-only endpoint, unlike anything the real client
            # ever sends. Untested hypothesis: worth an honest data point,
            # not a confirmed fix - see data/claude-quota-history.jsonl going
            # forward.
            "anthropic-version": "2023-06-01",
            "Accept": "application/json",
            "User-Agent": "claude-cli/2.1.251 (external, cli)",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            d_body = json.loads(resp.read())
            d_headers = {k: v for k, v in resp.headers.items() if k.lower() in HEADERS_TO_KEEP}
            return d_body, d_headers, None
    # HTTPError first - it subclasses URLError. The status is the whole point:
    # 401 means the OAuth access token expired (8 h lifetime): this poller only
    # reads it and never renews it, so it 401s whenever no `claude` process ran
    # here in the last 8 h - the next `claude` run renews it. Only if the
    # refresh token itself expired (refreshTokenExpiresAt) is a re-login needed. 429
    # means our own 5-minute polling is being rate-limited, 5xx is Anthropic's
    # side. Those need completely different responses, and until now the log
    # recorded all three identically as `"api": null`.
    except urllib.error.HTTPError as exc:
        d_err = {"stage": "http", "type": "HTTPError",
                 "status": exc.code, "detail": exc.reason}
        # 2026-08-30: mitmproxy capture showed the server DOES send a real
        # Retry-After on 429 (e.g. 1820s) - this poller was silently
        # discarding it (HEADERS_TO_KEEP never covered it, and only the
        # success path even looked at headers) and retrying every 60-300s
        # regardless, almost certainly re-tripping the exact backoff window
        # the server asked for. The entrypoint now waits it out (exit 75).
        retry_after = exc.headers.get("Retry-After") if exc.headers else None
        if retry_after is not None:
            try:
                d_err["retry_after_s"] = int(retry_after)
            except ValueError:
                pass
        return None, None, d_err
    except urllib.error.URLError as exc:
        # No HTTP status at all - offline, DNS, TLS, or the 5s timeout.
        return None, None, {"stage": "network", "type": type(exc).__name__,
                            "detail": str(exc.reason)}
    except json.JSONDecodeError as exc:
        # 200 OK but the body isn't JSON - e.g. a captive portal's login page.
        return None, None, {"stage": "parse", "type": "JSONDecodeError",
                            "detail": exc.msg}
    except OSError as exc:
        # Transport failures urllib doesn't wrap in URLError - e.g.
        # http.client.RemoteDisconnected when the server closes the
        # connection mid-request. Before this, they crashed the run and left
        # no row at all (7 times by 2026-09-29, see logs/quota-poll.err).
        return None, None, {"stage": "network", "type": type(exc).__name__,
                            "detail": str(exc)}


def sync(host: str, every: int, now: int) -> tuple[str, bool]:
    """The 2-min sync with HOST, when due. Returns (what to say, stale):
    stale = the last successful sync is older than SYNC_STALE_S."""
    try:
        d_state = json.loads(SYNC_STATE.read_text())
    except (OSError, ValueError):
        d_state = {"sent": 0, "received": 0, "last_ok_ts": 0}
    if now - d_state["last_ok_ts"] < every:
        return "", False
    me = usage_db.machine_name()
    db = usage_db.open_account("claude")
    l_mine, sent = ingest_account_quota.own_rows_after(db, me, d_state["sent"])
    payload = "".join(json.dumps({"raw": raw, "machine": me}, separators=(",", ":")) + "\n" for _, raw in l_mine)
    try:
        result = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host,
             SYNC_COMMAND.format(me=me, after=d_state["received"])],
            input=payload, capture_output=True, text=True, timeout=SYNC_TIMEOUT_S)
        if result.returncode != 0:
            raise RuntimeError(f"exit {result.returncode}")
        # JSON lines only: a login script may print a banner first.
        l_lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
        d_end = json.loads(l_lines[-1])
        received = int(d_end["max_rowid"])
    except (OSError, subprocess.TimeoutExpired, RuntimeError, ValueError, KeyError, IndexError) as exc:
        stale = now - d_state["last_ok_ts"] >= SYNC_STALE_S
        print(f"sync with {host} failed ({type(exc).__name__}: {exc}); next run retries", file=sys.stderr, flush=True)
        return f"{host} not reached", stale
    d_got = ingest_account_quota.add_synced(db, "claude", [line for line in l_lines[:-1] if '"raw"' in line])
    if d_end.get("rejected") or d_got["rejected"]:
        print(f"sync: rejected {d_end.get('rejected')} there, {d_got['rejected']} here", file=sys.stderr, flush=True)
    d_state |= {"sent": sent, "received": received, "last_ok_ts": now}   # other keys (seeded_through) kept
    SYNC_STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = SYNC_STATE.with_name(f"{SYNC_STATE.name}.tmp")
    tmp.write_text(json.dumps(d_state))
    tmp.replace(SYNC_STATE)
    return f"sync ↑{d_end.get('inserted', 0)} ↓{d_got['inserted']}", False


def newest_age(now: int, account: str | None = None, is_main: bool = True) -> int | None:
    """Seconds since the account's newest reading, any source, any machine. The main account: the `latest` view;
    another account (its organization uuid): `latest_by_account`. None: no reading (or a database not yet migrated)."""
    db = usage_db.open_account("claude", readonly=True)
    if db is None:
        return None
    try:
        if is_main:
            row = db.execute("SELECT ts FROM latest").fetchone()
        elif account:
            row = db.execute("SELECT ts FROM latest_by_account WHERE account = ?", (account,)).fetchone()
        else:
            row = None
    except Exception:           # a database before the v4 migration has no latest_by_account
        row = None
    return now - row[0] if row else None


def read_waits() -> dict:
    try:
        return {k: int(v) for k, v in json.loads(WAIT_STATE.read_text()).items()}
    except (OSError, ValueError, AttributeError, TypeError):
        return {}


def write_waits(d_waits: dict, now: int) -> None:
    WAIT_STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = WAIT_STATE.with_name(WAIT_STATE.name + ".tmp")
    tmp.write_text(json.dumps({k: v for k, v in d_waits.items() if v > now}))
    tmp.replace(WAIT_STATE)


def _pct(d_window) -> str:
    pct = d_window.get("utilization") if isinstance(d_window, dict) else None
    return "?" if pct is None else f"{pct:.0f}"


def poll_account(d_acct: dict, if_older_than: int, now: int, d_waits: dict) -> tuple[str, str, int | None]:
    """One account: skip when its newest reading is young or its 429 wait is running, else one attempt (one start =
    at most one attempt per account). Returns (outcome, text, retry_after_s): outcome is "skip", "ok", "429" or "fail"."""
    name = d_acct["name"]
    if d_waits.get(name, 0) > now:
        return "skip", f"429 wait {d_waits[name] - now} s", None
    age = newest_age(now, d_acct["org_uuid"], d_acct["is_main"])
    if age is not None and age < if_older_than:
        return "skip", f"quota fresh enough ({age} s)", None
    token, d_error = fetch_token(d_acct["config_dir"], d_acct["is_main"])
    d_api = d_api_headers = None
    if token:
        d_api, d_api_headers, d_error = fetch_usage(token)
    d_record = {
        "ts": int(time.time()),
        "iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": "claude_api",  # "claude" before 2026-10-04 (renamed in place by rename_sources.py)
        "machine": usage_db.machine_name(),  # since 2026-10-10: which machine's token took it
        "api": d_api,
        "api_headers": d_api_headers,
        "error": d_error,  # None on success; why the reading is missing otherwise
    }
    if d_acct["org_uuid"]:
        d_record["account"] = d_acct["org_uuid"]   # since 2026-11-19: whose reading (the gate falls back to the header)
    d_record["account_name"] = name
    # The gate stores a reading in account_quotas, a failed attempt in poll_errors.
    ingest_account_quota.add_row(usage_db.open_account("claude"), "claude", d_record, json.dumps(d_record))
    if d_error is None:
        return "ok", f"5h {_pct(d_api.get('five_hour'))}% · 7d {_pct(d_api.get('seven_day'))}%", None
    if d_error.get("status") == 429:
        return "429", "retry-after", int(d_error.get("retry_after_s") or 0)
    return "fail", "failed: " + " ".join(str(d_error[k]) for k in ("stage", "type", "status") if d_error.get(k) is not None), None


def main(argv: list[str] | None = None) -> None:
    import argparse
    parser = argparse.ArgumentParser(description="One reading of each Claude account's quota (see the module docstring).")
    parser.add_argument("--sync-with", metavar="HOST", help="first the 2-min sync of the readings with HOST (the Mac only)")
    parser.add_argument("--sync-every", type=int, default=110, metavar="SECONDS", help="with --sync-with: sync when the last one is this old")
    parser.add_argument("--if-older-than", type=int, default=0, metavar="SECONDS",
                        help="poll an account only if its newest reading is at least this old")
    args = parser.parse_args(argv)
    now = int(time.time())
    said, stale = sync(args.sync_with, args.sync_every, now) if args.sync_with else ("", False)
    tail = f" · {said}" if said else ""

    # The accounts of this machine (2026-11-19): none readable (a bare test runtime) = the main account alone, as before.
    l_accounts = claude_accounts.local_accounts()
    claude_accounts.write_cache(l_accounts)
    try:
        ingest_account_quota.upsert_accounts(usage_db.open_account("claude"), [a for a in l_accounts if a["org_uuid"]], now)
    except Exception as exc:
        print(f"accounts table not updated ({type(exc).__name__}: {exc})", file=sys.stderr, flush=True)
    d_waits = read_waits()
    # An account folder not logged in yet (no organization uuid) has no token to read: left out, not a failed attempt per minute.
    l_accounts = [a for a in l_accounts if a["is_main"] or a["org_uuid"]]
    l_results = [(a, *poll_account(a, args.if_older_than, now, d_waits)) for a in l_accounts]
    # A 429 wait kept here: another account's always (the job's WAIT cannot hold one account only); the main
    # account's only when another account was read in this run (the run then succeeds, so the job's own WAIT,
    # exit 75, does not hold the main account back).
    others_read = any(o == "ok" for _, o, _, _ in l_results[1:])
    for a, outcome, _, retry in l_results:
        if outcome == "429" and (not a["is_main"] or others_read):
            d_waits[a["name"]] = now + retry
    write_waits(d_waits, now)

    others = "".join(f" · {a['name']} {text}" for a, outcome, text, _ in l_results[1:] if outcome != "skip")
    # The exit follows the main account (what the job and its dashboard mean), except: it skipped and another account
    # was read -> success. A failure of another account (a login not used for 8 h reads 401) is in the line, never a failed run.
    _, outcome, text, retry = l_results[0]
    if outcome == "skip" and any(o == "ok" for _, o, _, _ in l_results[1:]):
        print(f"{text}{others}{tail}")
        sys.exit(1 if stale else 0)
    if outcome == "skip":
        print(f"{text}{others}{tail}")
        sys.exit(1 if stale else 10)
    if outcome == "ok":
        print(f"{text}{others}{tail}")
        sys.exit(1 if stale else 0)
    if outcome == "429":
        if any(o == "ok" for _, o, _, _ in l_results[1:]):   # the other accounts go on; the main one waits in WAIT_STATE
            print(f"{text} {retry}{others}{tail}")
            sys.exit(1 if stale else 0)
        print(f"{said + ' · ' if said else ''}retry-after {retry}")
        sys.exit(75)
    print(text + others + tail)
    sys.exit(1)


def offer_latest() -> None:
    """After every run, whatever its outcome (a reading, a skip, a sync that brought another machine's readings): each
    account's newest reading to its file, if fresher than the one there: the main account's data/claude/quota_latest.json,
    another's quota_latest.<name>.json (agent_tracker.offer_quota_from_db). Never fails the run."""
    try:
        import agent_tracker
        agent_tracker.offer_quota_from_db("claude")
        for d_acct in claude_accounts.local_accounts()[1:]:
            if d_acct["org_uuid"]:
                agent_tracker.offer_quota_from_db("claude", account=d_acct["org_uuid"], name=d_acct["name"])
    except Exception as exc:
        print(f"quota_latest.json not updated ({type(exc).__name__}: {exc})", file=sys.stderr, flush=True)


if __name__ == "__main__":
    try:
        main()
    finally:
        offer_latest()
