#!/usr/bin/env python3
"""Compatibility wrapper, kept until the statusline is switched at deploy
(doc/deploy_migration.md): agent-statusline's old Claude render pipes every
payload here (its path, ~/opt/<runtime>/src/statusline_payload_reader.py, was
the contract: doc/design.md §7.1) and shows the line printed back. The new
chain is `agent-tracker tick | display` (my-setup), which records the same
payload (statusline_usage.store, shared) and the display reads
data/claude/quota_latest.json instead of this line.

What it does, unchanged since 2026-08: stores the payload through
statusline_usage.store(), then prints the account's freshest reading - the
`latest` view: any source, any machine, the reset rule applied - as one line
of six fields separated by \x1c, the format agent-statusline and
auto-job-apply read:
    five_pct five_reset week_pct week_reset source observed_at
(percents rounded half up; a reset that has passed is empty), or nothing
when there is no reading. Always exits 0 and prints nothing else.

A failure is never shown; the last one, with its traceback, is in
logs/statusline_reader.err (overwritten). install.sh writes its first line
(this machine's python with -S) and MACHINE_NAME below.

Usage: <claude statusline payload JSON> | statusline_payload_reader.py
"""
import json
import os
import sys
import time

import ingest_account_quota
import statusline_usage
import usage_db

# This machine's name, written here by install.sh (skill machine-name):
# usage_db.machine_name() honours JR_MACHINE_NAME first, so a render needs no scutil call (~13 ms).
MACHINE_NAME = "__MACHINE_NAME__"

# Kept as names of this module: older tests and readers import them from here.
observed_at = statusline_usage.observed_at
store = statusline_usage.store


def latest_line() -> str | None:
    """The six fields of the account's freshest reading, or None."""
    db = usage_db.open_account("claude", readonly=True)
    row = db and db.execute("SELECT five_hour_pct, five_hour_resets_ts, seven_day_pct, seven_day_resets_ts, source, ts "
                            "FROM latest").fetchone()
    if not row:
        return None
    five, five_reset, week, week_reset, source, ts = row
    return ingest_account_quota.FIELD_SEP.join([
        str(ingest_account_quota._round(five)), str(five_reset or ""),
        str(ingest_account_quota._round(week)), str(week_reset or ""), source, str(ts)])


# The last failure, for whoever troubleshoots: the statusline must never see an
# error, so without this file a broken reader would go unnoticed. Overwritten,
# never appended: it cannot grow, and its time says whether it is current.
ERROR_LOG = usage_db.RUNTIME_DIR / "logs" / "statusline_reader.err"


def log_error(stage: str) -> None:
    try:
        import traceback  # only on a failure: the normal render stays fast
        ERROR_LOG.parent.mkdir(parents=True, exist_ok=True)
        ERROR_LOG.write_text(f"{usage_db.iso(int(time.time()))} {stage} failed\n{traceback.format_exc()}")
    except Exception:
        pass


def main() -> None:
    if not MACHINE_NAME.startswith("__"):  # left as is in the repo; filled in when deployed
        os.environ.setdefault("JR_MACHINE_NAME", MACHINE_NAME)
    try:
        store(json.loads(sys.stdin.read()))
    except Exception:  # a bad payload or a store failure must not cost the display
        log_error("storing the payload")
    try:
        line = latest_line()
    except Exception:
        log_error("reading latest")
        line = None
    if line:
        print(line, flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception:  # never let anything reach the statusline
        pass
    sys.exit(0)
