#!/bin/bash
# Tests for src/quota_rules.py: data/claude/quota_rules.json (2026-11-27). A sandbox HOME and runtime; readings written
# straight into a fresh account_quotas.db (usage_db's schema), two accounts on one plan, a third on another.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

SRC_DIR="$REPO_ROOT/src"
S="$(mktemp -d "${TMPDIR:-/tmp}/th-quota-rules.XXXXXX")"
trap 'rm -rf "$S"' EXIT
export HOME="$S/home" AGENT_TRACKER_HOME="$S/rt" AGENT_TRACKER_BILLING="$S/billing.json"
UA="11111111-1111-4111-8111-111111111111"; UB="22222222-2222-4222-8222-222222222222"; UC="33333333-3333-4333-8333-333333333333"
mkdir -p "$HOME/.claude/account-a" "$HOME/.claude/account-b" "$HOME/.claude/account-c"
login() { echo '{"oauthAccount":{"organizationUuid":"'$2'","organizationRateLimitTier":"'$3'"}}' > "$HOME/.claude/account-$1/.claude.json"; }
login a $UA default_claude_max_5x; login b $UB default_claude_max_5x; login c $UC default_claude_max_20x

# NOW: a Saturday 15:00 UTC. a's week resets Monday 19:00 UTC, b's Wednesday 06:00 UTC. In each 5-hour window of the
# last 3 weeks: a and b gain 5h +40 for 7d +5 (ratio 8), except one window per account of ratio 2 (a 7d jump); c none.
python3 - "$SRC_DIR" "$UA" "$UB" <<'PY'
import sys, json, datetime as dt
sys.path.insert(0, sys.argv[1]); import usage_db
db = usage_db.open_account("claude")
NOW = int(dt.datetime(2026, 11, 28, 15, tzinfo=dt.timezone.utc).timestamp())
MON19 = int(dt.datetime(2026, 11, 30, 19, tzinfo=dt.timezone.utc).timestamp())
WED06 = int(dt.datetime(2026, 12, 2, 6, tzinfo=dt.timezone.utc).timestamp())
n, d_p7 = 0, {}
for uuid, week_end in ((sys.argv[2], MON19), (sys.argv[3], WED06)):
    for k, start in enumerate(range(NOW - 21 * 86400, NOW - 6 * 3600, 86400)):   # one 5-hour window a day
        end5 = start + 5 * 3600
        end7 = week_end - ((week_end - start) // (7 * 86400)) * 7 * 86400
        if end7 <= start: end7 += 7 * 86400
        if end7 not in d_p7: d_p7[end7] = 1.0          # the 7-day % only grows within its week
        for i, (p5, d7) in enumerate(((5, 0), (45, 20 if k == 3 else 5))):
            d_p7[end7] += d7
            n += 1
            raw = json.dumps({"n": n})
            db.execute("INSERT INTO account_quotas (ts, dt, source, five_hour_pct, five_hour_resets_ts, seven_day_pct, "
                       "seven_day_resets_ts, written_ts, raw, row_hash, machine, account) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                       (start + 600 + i * 3600, usage_db.iso(start), "claude_api", p5, end5 + (i % 2), d_p7[end7],
                        end7, start, raw, usage_db.row_hash(raw), "m", uuid))
PY
cat > "$AGENT_TRACKER_BILLING" <<'J'
{"accounts": {"a": {"day_of_month": 31, "source": "test"}, "b": {"day_of_month": 20, "source": "test"}}}
J
NOW=$(python3 -c 'import datetime as dt; print(int(dt.datetime(2026, 11, 28, 15, tzinfo=dt.timezone.utc).timestamp()))')
out() { python3 -c "import sys, json, time; sys.path.insert(0, '$SRC_DIR'); import quota_rules as q
d = q.build($NOW)
$1"; }

section "the unit and the plans"
assert_eq "point = a full 5-hour window of a" "point = one full 5-hour window of account a" "$(out 'print(d["unit"])')"
assert_eq "plans read from each login" "default_claude_max_5x default_claude_max_5x default_claude_max_20x" \
    "$(out 'print(*(d["accounts"][n]["plan"] for n in "abc"))')"
assert_eq "same plan as a: factor 1; another plan: null (never compared)" "1.0 1.0 None" \
    "$(out 'print(*(d["accounts"][n]["account_factor"] for n in "abc"))')"

section "5-hour windows per week: measured, pooled per plan"
assert_eq "median 8 over a's and b's windows (the two jumps of ratio 2 do not move it)" "8.0 8.0" \
    "$(out 'print(d["accounts"]["a"]["five_hour_windows_per_week"]["median"], d["accounts"]["b"]["five_hour_windows_per_week"]["median"])')"
assert_eq "n by account" '{"a": 21, "b": 21}' "$(out 'print(json.dumps(d["accounts"]["a"]["five_hour_windows_per_week"]["n_by_account"]))')"
assert_eq "points per 1%: 5h 0.01, 7d 0.08" "0.01 0.08" "$(out 'x = d["accounts"]["b"]; print(x["points_per_5h_pct"], x["points_per_7d_pct"])')"
assert_eq "c: no window, no points" "None None" "$(out 'x = d["accounts"]["c"]; print(x["five_hour_windows_per_week"], x["points_per_7d_pct"])')"

section "weekly reset: fixed weekday and UTC time, the next one"
assert_eq "a: Mon 19:00, next 2026-11-30" "Mon 19:00 2026-11-30T19:00:00Z" \
    "$(out 'w = d["accounts"]["a"]["weekly_reset"]; print(w["weekday_utc"], w["time_utc"], w["next_dt"])')"
assert_eq "b: Wed 06:00, next 2026-12-02" "Wed 06:00 2026-12-02T06:00:00Z" \
    "$(out 'w = d["accounts"]["b"]["weekly_reset"]; print(w["weekday_utc"], w["time_utc"], w["next_dt"])')"

section "billing: from billing.json; a short month takes its last day"
assert_eq "a: the 31st, next in November = the 30th" "2026-11-30T00:00:00Z" "$(out 'print(d["accounts"]["a"]["billing"]["next_dt"])')"
assert_eq "b: the 20th, next 2026-12-20" "2026-12-20T00:00:00Z test" "$(out 'b = d["accounts"]["b"]["billing"]; print(b["next_dt"], b["source"])')"
assert_eq "c: no entry, null" "None" "$(out 'print(d["accounts"]["c"]["billing"])')"

section "the file: written atomically, not rewritten when nothing changed"
assert_contains "first run writes" "$(python3 "$SRC_DIR/quota_rules.py")" "written:"
assert_eq "valid JSON with three accounts" "3" "$(jq '.accounts | length' "$AGENT_TRACKER_HOME/data/claude/quota_rules.json")"
assert_contains "second run: unchanged" "$(python3 "$SRC_DIR/quota_rules.py")" "unchanged:"

harness_summary
