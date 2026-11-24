#!/usr/bin/env python3
"""One page of Claude's token use and quotas, built when you want to look: usage-dashboard.

Run:  usage-dashboard [--hours 48] [--no-open] [--publish]   (~/.local/bin/usage-dashboard -> ~/opt/agent-tracker/src/dashboard.py, install.sh)
The data lives on the central (the NAS, babisnas): every machine's `slots` (data/claude/aggregates/<machine>.db, Category 3)
and both accounts' quota readings (data/claude/account_quotas.db, Category 1). On the NAS this reads them directly; anywhere else
it runs itself there over ssh with --data (which prints the page's data as JSON) - like resource-guard's resource-dashboard.
Then it writes ~/opt/agent-tracker/out/dashboard.html (template dashboard.html beside this file; the look, charts and build from
resource-guard's dashkit, deployed in ~/opt/resource-guard/dashkit/, shared with resource-dashboard), prints its file:// link
and, in a terminal on the Mac, opens it. --publish: also updates the private Artifact page (dashkit.DASHBOARDS) through
`claude -p` (~2% of Claude's window; log ~/opt/agent-tracker/logs/publish.log). A reader of this repo's data
(doc/design.md §1, Category 4): it only reads, with PRAGMA query_only (FOR_READERS.md).
"""
import json, os, pathlib, sqlite3, subprocess, sys, time

CENTRAL = "babisnas"                 # the ssh host that holds every machine's slots (doc/design.md §6.4)
CENTRAL_MACHINE = "BabisNAS"         # its machine name (skill machine-name)
HERE = pathlib.Path(__file__).resolve().parent
RUNTIME = pathlib.Path(os.environ.get("AGENT_TRACKER_HOME") or pathlib.Path.home() / "opt" / "agent-tracker")
DASHKIT = pathlib.Path(os.environ.get("DASHKIT_DIR") or pathlib.Path.home() / "opt" / "resource-guard" / "dashkit")
DIMS = ["repo", "kind", "machine", "job", "account", "model", "entrypoint"]
sys.path.insert(0, str(HERE))
import usage_db   # noqa: E402  project() (folder -> repo), kind() (development / test run / scheduled run), machine_name()
TOKENS = "input_tokens, output_tokens, cache_read_tokens, cache_write_5m_tokens + cache_write_1h_tokens + cache_write_unknown_tokens"


def connect(path):
    db = sqlite3.connect(str(path))
    db.execute("PRAGMA query_only = ON")
    return db


def bin_for(hours):
    """The bar width: an hour up to 8 days, a day beyond."""
    return 3600 if hours <= 192 else 86400


def data(hours):
    """Everything the page draws, from this machine's runtime (the central's): a dict, JSON-ready."""
    now = int(time.time())
    t0 = now - int(hours * 3600)
    step = bin_for(hours)
    t0b = t0 - t0 % step
    q = connect(RUNTIME / "data" / "claude" / "account_quotas.db")
    d_acct = dict(q.execute("SELECT org_uuid, name FROM accounts"))
    main = next((u for u, n in d_acct.items() if n == "a"), None)   # a reading or slot with no account: account a (doc/tables.md §3.5)
    name = lambda u: d_acct.get(u or main, (u or "?")[:8])

    # Category 3: slots of every machine, summed per bar and per dimension value
    vals = {k: [] for k in DIMS}
    idx = lambda k, v: vals[k].index(v) if v in vals[k] else (vals[k].append(v) or len(vals[k]) - 1)
    d_rows = {}
    for f in sorted((RUNTIME / "data" / "claude" / "aggregates").glob("*.db")):
        db = connect(f)
        for r in db.execute("SELECT (ts / %d) * %d, folder, machine, job, account, model, entrypoint, requests, %s, usd, tokens_without_usd "
                            "FROM slots WHERE ts >= ?" % (step, step, TOKENS), (t0b,)):
            key = (r[0], idx("repo", usage_db.project(r[1])), idx("kind", usage_db.kind(r[1], r[6])), idx("machine", r[2]), idx("job", r[3] or "(interactive)"),
                   idx("account", name(r[4]) if r[4] else "(unknown)"), idx("model", r[5]), idx("entrypoint", r[6] or "(unknown)"))
            acc = d_rows.setdefault(key, [0, 0, 0, 0, 0, None, 0])
            for i, v in enumerate(r[7:12]):
                acc[i] += v
            if r[12] is not None:
                acc[5] = (acc[5] or 0) + r[12]
            acc[6] += r[13]
        db.close()
    # rows: [bar ts, repo, kind, machine, job, account, model, entrypoint (indexes into dims), requests, input, output, cache read, cache write, usd, tokens without usd]
    l_rows = [list(k) + v[:5] + [None if v[5] is None else round(v[5], 4), v[6]] for k, v in sorted(d_rows.items())]

    # Category 1: quota readings per account, 5-hour and 7-day % (both sources: the statusline's and the API poller's)
    d_q = {}
    for ts, acct, p5, r5, p7, r7 in q.execute(
            "SELECT ts, account, five_hour_pct, five_hour_resets_ts, seven_day_pct, seven_day_resets_ts FROM account_quotas "
            "WHERE ts >= ? AND ts <= ? AND (five_hour_pct IS NOT NULL OR seven_day_pct IS NOT NULL) ORDER BY ts, rowid", (t0, now)):
        d_q.setdefault(name(acct), []).append([ts, p5, r5, p7, r7])
    d_quota = {a: quota_series(l, now) for a, l in sorted(d_q.items())}
    latest = [dict(zip(("name", "ts", "source", "machine", "five_hour_pct", "five_hour_resets_ts", "seven_day_pct", "seven_day_resets_ts"), r))
              for r in q.execute("SELECT COALESCE(name, substr(account, 1, 8)), ts, source, machine, five_hour_pct, five_hour_resets_ts, "
                                 "seven_day_pct, seven_day_resets_ts FROM latest_by_account ORDER BY name")]
    q.close()
    return {"t0": t0, "now": now, "step": step, "dims": vals, "rows": l_rows, "quota": d_quota, "latest": latest}


def quota_series(l, now, bucket=300):
    """Readings [ts, 5h %, its reset, 7d %, its reset] -> {ts, five, seven}: the last reading of each 5-minute bucket, and the
    reset rule (doc/design.md: a window whose reset time has passed reads 0%) drawn as a drop to 0 at the reset when no reading
    shows it."""
    pts = {}
    for ts, p5, r5, p7, r7 in l:
        pts[ts - ts % bucket] = [p5, r5, p7, r7]
    l_ts = sorted(pts)
    out = {"ts": [], "five": [], "seven": []}
    def add(t, a, b):
        out["ts"].append(t), out["five"].append(a), out["seven"].append(b)
    for k, t in enumerate(l_ts):
        p5, r5, p7, r7 = pts[t]
        add(t, p5, p7)
        t_next = l_ts[k + 1] if k + 1 < len(l_ts) else now
        resets = sorted({r for r in (r5, r7) if r and t < r < t_next})
        for r in resets:                                    # a reset between this reading and the next: 0 from then on
            p5 = 0.0 if r5 and r5 <= r else p5
            p7 = 0.0 if r7 and r7 <= r else p7
            add(r, p5, p7)
    return out


def main():
    if "--data" in sys.argv:                                # on the central, called by another machine: no dashkit needed
        hours = float(sys.argv[sys.argv.index("--hours") + 1]) if "--hours" in sys.argv else 48
        json.dump(data(hours), sys.stdout, separators=(",", ":"))
        return
    sys.path.insert(0, str(DASHKIT))
    import dashkit
    ap = dashkit.parser(__doc__.split("\n")[0].replace(": usage-dashboard.", ""), default_hours=48)
    ap.add_argument("--data", action="store_true", help="print the page's data as JSON and stop (run on the central by the other machines)")
    args = ap.parse_args()
    if usage_db.machine_name() == CENTRAL_MACHINE:
        d = data(args.hours)
    else:
        r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", CENTRAL,
                            "~/.local/bin/usage-dashboard --data --hours %g" % args.hours], capture_output=True, text=True, timeout=180)
        if r.returncode != 0:
            sys.exit("usage-dashboard: no data from %s (exit %d): %s" % (CENTRAL, r.returncode, r.stderr.strip()[-500:]))
        d = json.loads(r.stdout)
    d.update(hours=args.hours, made=dashkit.made(), nav=dashkit.nav("agent-tracker", args.publish))
    out = dashkit.build(HERE / "dashboard.html", dashkit.rounded(d, 3), RUNTIME / "out" / "dashboard.html")
    print("%d bars of %d s, %d rows, quota readings: %s" % (
        len({r[0] for r in d["rows"]}), d["step"], len(d["rows"]), ", ".join("%s %d" % (a, len(s["ts"])) for a, s in d["quota"].items()) or "none"))
    dashkit.show(out, args.no_open)
    if args.publish:
        sys.exit(dashkit.publish(out, dashkit.artifact_url("agent-tracker"), RUNTIME / "logs" / "publish.log"))


if __name__ == "__main__":
    main()
