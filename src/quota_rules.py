#!/usr/bin/env python3
"""How big each Claude account's quota is, when its week resets and when it is billed: data/claude/quota_rules.json
(the user, 2026-11-27: one file a reader such as my-setup's `claude` command reads to compare accounts in one unit).

  unit                      "point" = one full 5-hour window of the reference account (the first by name, a)
  plan                      the account's rate-limit tier, from its .claude.json (`oauthAccount.organizationRateLimitTier`)
  account_factor            how many points one full 5-hour window of this account is: 1.0 when its plan is the
                            reference's; null when the plans differ (no measured factor between two plans yet: a reader
                            must not compare them, FOR_READERS rule 11)
  five_hour_windows_per_week  measured, per plan (every account on that plan pooled: the limits are the plan's): within
                            each 5-hour window of the last WINDOW_DAYS days, (5-hour % gained) / (7-day % gained);
                            median, p10, p90, n and n per account. Only windows that gained MIN_GAIN_5H on the 5-hour
                            meter and MIN_GAIN_7D on the 7-day one: below, the 1% steps of the 7-day meter swing the
                            ratio from 5 to 40 (adhoc_quotas_analysis/CONCLUSIONS.md §2)
  points_per_5h_pct, points_per_7d_pct   what 1% of each meter is worth, in points
  weekly_reset              the 7-day window's reset: fixed per account (a weekday and a UTC time, every 7 days), the most
                            frequent reset time of the readings, and the next one
  billing                   the monthly billing day, from ~/.config/agent-tracker/billing.json (stated facts with their
                            source: the receipts; a plan change moves the day, so it is never guessed from the login file).
                            Kept out of this repo: it is public. null when the file has no entry for the account

Reads (never writes) data/claude/account_quotas.db (FOR_READERS rule 2), each account's .claude.json, billing.json.
Writes data/claude/quota_rules.json atomically (temp file + rename), only when its content changed (besides ts/dt).
Run: python3 src/quota_rules.py [--print]; the job agent-tracker.quota-rules runs it every hour.
"""
from __future__ import annotations

import calendar
import collections
import datetime as dt
import json
import os
import sqlite3
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import claude_accounts  # noqa: E402
import usage_db  # noqa: E402

WINDOW_DAYS = 28          # the ratio is measured on this many recent days (use changes; so may the limits)
MIN_GAIN_5H = 10          # % gained on the 5-hour meter within the window
MIN_GAIN_7D = 2           # % gained on the 7-day meter within the same window
MIN_WINDOWS = 5           # fewer: also use older windows of the same plan, back to the plan's first reading
GRID_S = 600              # reset times jitter by a second; Claude rounds a 5-hour end to 10 min (load.GRID_S)
WEEK_S = 7 * 86400
FIVE_H_S = 5 * 3600


def billing_path() -> Path:
    return Path(os.environ.get("AGENT_TRACKER_BILLING") or Path.home() / ".config" / "agent-tracker" / "billing.json")


def read_json(path: Path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def plan_of(config_dir: str, name: str) -> str | None:
    """The rate-limit tier of the account's login (its .claude.json; legacy a: ~/.claude.json)."""
    path = Path(config_dir) / ".claude.json"
    if name == "a" and not claude_accounts.a_moved():
        path = Path.home() / ".claude.json"
    d = read_json(path) or {}
    return (d.get("oauthAccount") or {}).get("organizationRateLimitTier")


def connect(path: Path):
    db = sqlite3.connect(path, timeout=10, isolation_level=None)
    db.execute("PRAGMA busy_timeout = 10000")
    db.execute("PRAGMA query_only = ON")
    return db


def readings(db, org_uuid: str, is_a: bool, since: int) -> list[tuple]:
    """(ts, 5h %, 5h reset, 7d %, 7d reset) of one account since `since`, oldest first (NULL account = a, rule 19)."""
    where = "(account = ? OR account IS NULL)" if is_a else "account = ?"
    return db.execute(
        "SELECT ts, five_hour_pct, five_hour_resets_ts, seven_day_pct, seven_day_resets_ts FROM account_quotas "
        f"WHERE {where} AND ts >= ? ORDER BY ts, rowid", (org_uuid, since)).fetchall()


def windows(l_rows: list[tuple], i_pct: int, i_end: int) -> dict:
    """{snapped end: [(ts, pct)]}: the first reading of each new highest percent (FOR_READERS rule 10)."""
    d_raw = collections.defaultdict(list)
    for row in l_rows:
        if row[i_pct] is not None and row[i_end] is not None:
            d_raw[round(row[i_end] / GRID_S) * GRID_S].append((row[0], row[i_pct]))
    d_out = {}
    for end, l_tp in d_raw.items():
        l_steps, top = [], -1.0
        for ts, pct in sorted(l_tp):
            if pct > top:
                l_steps.append((ts, pct))
                top = pct
        d_out[end] = l_steps
    return d_out


def ratios(l_rows: list[tuple]) -> list[float]:
    """(5-hour % gained) / (7-day % gained) within each 5-hour window that gained enough on both."""
    d5, d7 = windows(l_rows, 1, 2), windows(l_rows, 3, 4)

    def pct7_at(ts: int) -> float | None:
        for end, l_steps in d7.items():
            if end - WEEK_S <= ts < end:
                return max([p for t, p in l_steps if t <= ts] or [0.0])
        return None

    l_out = []
    for end, l_steps in sorted(d5.items()):
        if len(l_steps) < 2:
            continue
        (t0, p0), (t1, p1) = l_steps[0], l_steps[-1]
        q0, q1 = pct7_at(t0), pct7_at(t1)
        if q0 is None or q1 is None or p1 - p0 < MIN_GAIN_5H or q1 - q0 < MIN_GAIN_7D:
            continue
        l_out.append((p1 - p0) / (q1 - q0))
    return l_out


def quantile(l_v: list[float], f: float) -> float:
    l_v = sorted(l_v)
    return l_v[min(len(l_v) - 1, round(f * (len(l_v) - 1)))]


def weekly_reset(l_rows: list[tuple], now: int) -> dict | None:
    """The account's fixed weekly reset: its most frequent 7-day reset time (to the hour) modulo a week."""
    c_slot = collections.Counter()
    l_ends = set()
    for row in l_rows:
        if row[4] is not None:
            end = round(row[4] / 3600) * 3600
            l_ends.add(end)
            c_slot[end % WEEK_S] += 1
    if not c_slot:
        return None
    slot = c_slot.most_common(1)[0][0]
    nxt = now - (now - slot) % WEEK_S + WEEK_S if (now - slot) % WEEK_S else now
    first = dt.datetime.fromtimestamp(slot, dt.timezone.utc)   # the epoch week holds the weekday and time
    return {"weekday_utc": first.strftime("%a"), "time_utc": first.strftime("%H:%M"), "period_s": WEEK_S,
            "next_ts": nxt, "next_dt": iso(nxt), "weeks_seen": len({e for e in l_ends if e % WEEK_S == slot})}


def next_billing(day: int, now: int) -> int:
    """The next billing time (00:00 UTC of that day; a short month: its last day), strictly after now."""
    t = dt.datetime.fromtimestamp(now, dt.timezone.utc)
    for k in range(3):
        y, m = (t.year + (t.month - 1 + k) // 12), (t.month - 1 + k) % 12 + 1
        d = dt.datetime(y, m, min(day, calendar.monthrange(y, m)[1]), tzinfo=dt.timezone.utc)
        if d.timestamp() > now:
            return int(d.timestamp())
    raise ValueError(day)


def iso(ts: int) -> str:
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build(now: int) -> dict:
    l_accounts = [a for a in claude_accounts.local_accounts() if a["org_uuid"]]
    db = connect(usage_db.RUNTIME_DIR / "data" / "claude" / "account_quotas.db")
    d_billing = (read_json(billing_path()) or {}).get("accounts") or {}
    ref = l_accounts[0] if l_accounts else None
    ref_plan = plan_of(ref["config_dir"], ref["name"]) if ref else None
    # The ratio is a property of the plan, not of the login: pool the windows of every account on the same plan
    d_plan = {a["name"]: plan_of(a["config_dir"], a["name"]) for a in l_accounts}
    d_rows = {a["name"]: readings(db, a["org_uuid"], a["name"] == "a", now - WINDOW_DAYS * 86400) for a in l_accounts}
    d_ratios = {name: ratios(l_rows) for name, l_rows in d_rows.items()}
    since = now - WINDOW_DAYS * 86400
    if sum(map(len, d_ratios.values())) < MIN_WINDOWS:   # too few recent windows: the whole history
        d_ratios = {a["name"]: ratios(readings(db, a["org_uuid"], a["name"] == "a", 0)) for a in l_accounts}
        since = 0
    d_out = {}
    for a in l_accounts:
        plan = d_plan[a["name"]]
        l_rows = d_rows[a["name"]]
        l_same = [n for n in d_ratios if d_plan[n] == plan]
        l_r = [r for n in l_same for r in d_ratios[n]]
        per_week = ({"median": round(statistics.median(l_r), 2), "p10": round(quantile(l_r, 0.1), 2),
                     "p90": round(quantile(l_r, 0.9), 2), "n": len(l_r),
                     "n_by_account": {n: len(d_ratios[n]) for n in l_same}, "since_dt": iso(since)} if l_r else None)
        factor = 1.0 if plan and plan == ref_plan else None
        bill = d_billing.get(a["name"])
        d_out[a["name"]] = {
            "org_uuid": a["org_uuid"], "plan": plan,
            "account_factor": factor,
            "five_hour_windows_per_week": per_week,
            "points_per_5h_pct": round(factor / 100, 6) if factor is not None else None,
            "points_per_7d_pct": round(factor * per_week["median"] / 100, 6) if factor is not None and per_week else None,
            "weekly_reset": weekly_reset(l_rows or readings(db, a["org_uuid"], a["name"] == "a", now - 5 * WEEK_S), now),
            "billing": ({**bill, "next_ts": next_billing(int(bill["day_of_month"]), now),
                         "next_dt": iso(next_billing(int(bill["day_of_month"]), now))}
                        if isinstance(bill, dict) and bill.get("day_of_month") else None),
        }
    return {"ts": now, "dt": iso(now),
            "unit": f"point = one full 5-hour window of account {ref['name'] if ref else '-'}",
            "reference_account": ref["name"] if ref else None,
            "accounts": d_out}


def path() -> Path:
    return usage_db.RUNTIME_DIR / "data" / "claude" / "quota_rules.json"


def write(d: dict) -> bool:
    """Atomically; False (nothing written) when only ts/dt and the next reset/billing times would change."""
    strip = lambda d: json.dumps({k: v for k, v in d.items() if k not in ("ts", "dt")}, sort_keys=True)
    old = read_json(path())
    if old and strip(old) == strip(d) and time.time() - old.get("ts", 0) < 86400:
        return False
    path().parent.mkdir(parents=True, exist_ok=True)
    tmp = path().with_name(path().name + ".tmp")
    tmp.write_text(json.dumps(d, indent=1) + "\n")
    tmp.replace(path())
    return True


def summary(d: dict) -> str:
    l = []
    for name, x in d["accounts"].items():
        w = x["five_hour_windows_per_week"]
        l.append(f"{name}: {w['median'] if w else '?'} 5h/week" + (f", resets {x['weekly_reset']['weekday_utc']} "
                 f"{x['weekly_reset']['time_utc']}Z" if x["weekly_reset"] else ""))
    return " · ".join(l) or "no logged-in account"


if __name__ == "__main__":
    d = build(int(time.time()))
    if "--print" in sys.argv[1:]:
        print(json.dumps(d, indent=1))
        sys.exit(0)
    print(("written: " if write(d) else "unchanged: ") + summary(d))
