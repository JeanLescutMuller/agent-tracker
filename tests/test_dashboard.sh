#!/bin/bash
# Tests for src/dashboard.py (usage-dashboard): on a fixture runtime written through the gates, --data sums the slots
# per hour and per dimension (repo from usage_db.project, kind, account name), keeps each account's quota readings with
# the reset rule drawn as a drop to 0, and only reads. The page itself (dashkit, resource-guard) is built when the kit
# is installed here; its drawing is checked by hand in a headless Chrome (doc/changes.md, 2026-11-24).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-tracker-dashboard.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export AGENT_TRACKER_HOME="$TMP/rt" JR_MACHINE_NAME=m1
UA=11111111-aaaa-4aaa-8aaa-111111111111 UB=22222222-bbbb-4bbb-8bbb-222222222222
NOW=$(date +%s); H=$(( NOW - NOW % 3600 - 3 * 3600 ))   # an hour start, 3 hours ago

python3 - "$REPO_ROOT/src" "$UA" "$UB" "$H" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
import usage_db, ingest_account_quota as q, ingest_aggregates as g
UA, UB, H = sys.argv[2], sys.argv[3], int(sys.argv[4])
db = usage_db.open_account("claude")
q.upsert_accounts(db, [{"name": "a", "org_uuid": UA, "config_dir": "/h/a"}, {"name": "b", "org_uuid": UB, "config_dir": "/h/b"}])
def reading(t, acct, p5, end5, p7=10, end7=H + 5 * 86400):
    w = lambda p, e: {"utilization": p, "resets_at": usage_db.iso(e)}
    q.add_row(db, "claude", {"ts": t, "source": "claude_api", "machine": "m1", "account": acct,
                             "api": {"five_hour": w(p5, end5), "seven_day": w(p7, end7)}})
reading(H + 60, UA, 40, H + 3600)          # account a: 40% until its 5-hour window resets at H+1h, then a reading at H+2h
reading(H + 7200, UA, 5, H + 7200 + 5 * 3600)
reading(H + 600, UB, 80, H + 5 * 3600)
reading(H - 600, UB, 1, H + 2 * 86400)     # misdated (a resumed session, before 2026-11-24): a 5-hour reset 2 days ahead
def slot(t, folder, entrypoint, acct, usd, inp=100, cr=1000, req=1, job=""):
    return dict(ts=t, dt=usage_db.iso(t), machine="m1", folder=folder, entrypoint=entrypoint, job=job, account=acct,
                model="claude-opus-5-5", requests=req, input_tokens=inp, output_tokens=10, cache_read_tokens=cr,
                cache_write_5m_tokens=5, cache_write_1h_tokens=0, cache_write_unknown_tokens=0, usd=usd,
                tokens_without_usd=0 if usd is not None else inp + 10 + cr + 5, written_ts=t)
g.add_slots(usage_db.open_aggregates("claude"), [
    slot(H, "/Users/x/dev/agents/alpha", "cli", UA, 1.0), slot(H + 300, "/home/x/dev/agents/alpha/src", "cli", UA, 0.5),
    slot(H + 3600, "/Users/x/opt/beta", "sdk-cli", UB, None, job="beta.nightly"),
    slot(H + 3900, "/tmp/claude-1000/-home-x-dev-infra-gamma/u1/scratchpad", "cli", "", 2.0)])
PY
md5() { python3 -c 'import sqlite3, sys, hashlib; print(hashlib.md5("".join("".join(sqlite3.connect(p).iterdump()) for p in sys.argv[1:]).encode()).hexdigest())' "$TMP/rt/data/claude/"*.db "$TMP/rt/data/claude/aggregates/"*.db; }
before="$(md5)"

section "--data: slots per hour and dimension"
python3 "$REPO_ROOT/src/dashboard.py" --data --hours 6 > "$TMP/d.json"
python3 -c "import json; json.load(open('$TMP/d.json'))"; assert_status "valid JSON" 0 $?
q() { python3 -c "import json; d = json.load(open('$TMP/d.json')); print($1)"; }
assert_eq "one hour bars" "3600" "$(q 'd["step"]')"
assert_eq "repos: a Mac and a NAS path of one repo are one repo; ~/opt/<x> and a NAS scratchpad too" "['alpha', 'beta', 'gamma']" "$(q 'd["dims"]["repo"]')"
assert_eq "kinds" "['development', 'scheduled run']" "$(q 'd["dims"]["kind"]')"
assert_eq "accounts by name; no account: (unknown)" "['a', 'b', '(unknown)']" "$(q 'd["dims"]["account"]')"
assert_eq "jobs: none = (interactive)" "['(interactive)', 'beta.nightly']" "$(q 'd["dims"]["job"]')"
assert_eq "alpha's two slots of one hour summed: 2 requests, \$1.5" "[[2, 200, 20, 2000, 10, 1.5, 0]]" "$(q '[r[8:] for r in d["rows"] if r[1] == 0]')"
assert_eq "beta: no \$, every token counted without \$" "[[1, 100, 10, 1000, 5, None, 1115]]" "$(q '[r[8:] for r in d["rows"] if r[1] == 1]')"
assert_eq "the bar of a slot is its hour" "True" "$(q 'all(r[0] % 3600 == 0 for r in d["rows"])')"

section "--data: quota readings"
assert_eq "both accounts" "['a', 'b']" "$(q 'sorted(d["quota"])')"
assert_eq "account a: 40%, then 0 at its reset (H+1h), then 5%" "[40.0, 0.0, 5.0]" "$(q 'd["quota"]["a"]["five"]')"
assert_eq "the drop is at the reset time" "$(( H + 3600 ))" "$(q 'd["quota"]["a"]["ts"][1]')"
assert_eq "account b: the misdated reading is left out" "[80.0]" "$(q 'd["quota"]["b"]["five"]')"
assert_eq "latest per account" "a 5 b 80" "$(q '" ".join("%s %g" % (l["name"], l["five_hour_pct"]) for l in d["latest"])')"
assert_eq "the databases are unchanged: --data only reads" "$before" "$(md5)"

section "the page (when resource-guard's dashkit is installed here)"
KIT="${DASHKIT_DIR:-$HOME/opt/resource-guard/dashkit}"
if [ -f "$KIT/dashkit.py" ]; then
    out="$(JR_MACHINE_NAME=BabisNAS DASHKIT_DIR="$KIT" python3 "$REPO_ROOT/src/dashboard.py" --no-open --hours 6 2>&1)"
    assert_contains "built from the local data on the central" "$out" "rows, quota readings: a 3, b 1"
    assert_file_exists "the page" "$TMP/rt/out/dashboard.html"
    assert_not_contains "every placeholder filled" "$(cat "$TMP/rt/out/dashboard.html")" "/*DASHKIT_"
else
    echo "  (skipped: no dashkit at $KIT)"
fi
harness_summary
