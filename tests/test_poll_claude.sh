#!/bin/bash
# Unit tests for src/claude_quota_api_poller.py: fetch_usage's error
# handling (every transport failure must come back as an error dict, stored
# as a row, never escape and crash the run), where each outcome is stored,
# its exit codes and last lines (read by its job-runner entrypoint), the
# age check (--if-older-than), and the sync (--sync-with), with a fake ssh
# running the VM's gate in a second temp runtime.
# urlopen is monkeypatched - no network, no Keychain.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

SRC_DIR="$REPO_ROOT/src"

fetch_with() {
    python3 -c "
import sys, http.client, socket, urllib.error, urllib.request
sys.path.insert(0, '$SRC_DIR')
import claude_quota_api_poller as poll_claude
def boom(*a, **k): raise $1
urllib.request.urlopen = boom
body, headers, err = poll_claude.fetch_usage('dummy-token')
print(err['stage'], err['type'])
" 2>&1
}

section "server closes the connection -> network error row, no crash"
# Regression test: http.client.RemoteDisconnected is an OSError, not a
# URLError, and used to escape every handler (7 crashes by 2026-09-29).
assert_eq "RemoteDisconnected" "network RemoteDisconnected" \
    "$(fetch_with 'http.client.RemoteDisconnected("Remote end closed connection without response")')"
assert_eq "ConnectionResetError" "network ConnectionResetError" \
    "$(fetch_with 'ConnectionResetError(54, "Connection reset by peer")')"

section "existing failure classes keep their stage"
assert_eq "URLError stays a network error" "network URLError" \
    "$(fetch_with 'urllib.error.URLError("offline")')"

# poll_once <fetch_usage return expression> -> runs main() with the token
# and request faked, against a temp runtime; prints "<readings> <failed
# attempts> <latest view's source, or none>".
poll_once() {
    local dir; dir="$(mktemp -d "${TMPDIR:-/tmp}/th-poll.XXXXXX")"
    HOME="$dir" AGENT_TRACKER_HOME="$dir" python3 -c "
import sys
from pathlib import Path
sys.path.insert(0, '$SRC_DIR')
import claude_quota_api_poller as poll_claude
poll_claude.fetch_token = lambda *a: ('dummy', None)
poll_claude.fetch_usage = lambda token: $1
poll_claude.main()
" > /dev/null 2>&1
    python3 -c "
import sqlite3
d = sqlite3.connect('$dir/data/claude/account_quotas.db')
print(d.execute('SELECT COUNT(*) FROM account_quotas').fetchone()[0], d.execute('SELECT COUNT(*) FROM poll_errors').fetchone()[0], end=' ')
"
    python3 -c "
import sqlite3
row = sqlite3.connect('$dir/data/claude/account_quotas.db').execute('SELECT source FROM latest').fetchone()
print(row[0] if row else 'none')"
    rm -rf "$dir"
}

section "a reading goes to account_quotas, a failed attempt only to poll_errors"
assert_eq "success -> one reading, no failed attempt, latest from claude_api" "1 0 claude_api" \
    "$(poll_once "({'five_hour': {'utilization': 5, 'resets_at': '2026-10-08T12:00:00Z'}}, {}, None)")"
assert_eq "429 -> no reading, one failed attempt, nothing in latest" "0 1 none" \
    "$(poll_once "(None, None, {'stage': 'http', 'status': 429})")"

# A fake ssh: runs the remote command locally as machine "vm", with
# HOME=$PEER_HOME, whose ~/opt/agent-tracker/src is this repo's src/;
# PEER_HOME=down: unreachable. The local machine is "mac".
FAKE="$(mktemp -d "${TMPDIR:-/tmp}/th-peer.XXXXXX")"
trap 'rm -rf "$FAKE"' EXIT
mkdir -p "$FAKE/bin" "$FAKE/peer/opt/agent-tracker"
ln -s "$SRC_DIR" "$FAKE/peer/opt/agent-tracker/src"
cat > "$FAKE/bin/ssh" <<'SSH'
#!/bin/bash
while [ "$1" = -o ]; do shift 2; done
[ "$PEER_HOME" = down ] && exit 255
echo "a login banner"                 # what a login script may print first
env -u AGENT_TRACKER_HOME HOME="$PEER_HOME" JR_MACHINE_NAME=vm bash -c "$2"   # a real ssh passes no environment
SSH
chmod +x "$FAKE/bin/ssh"
LOCAL="$FAKE/local/opt/agent-tracker"
PEER="$FAKE/peer/opt/agent-tracker"
export PEER_HOME="$FAKE/peer"
peer_db() { python3 -c "
import sqlite3, sys
d = sqlite3.connect('$PEER/data/claude/account_quotas.db')
print(*d.execute(sys.argv[1]).fetchone(), sep='\t')" "$1"; }
local_db() { python3 -c "
import sqlite3, sys
d = sqlite3.connect('$LOCAL/data/claude/account_quotas.db')
print(*d.execute(sys.argv[1]).fetchone(), sep='\t')" "$1"; }

# poll <fetch_usage return expression> [poller args...] -> "<exit code> <last line>"; the local runtime is $LOCAL
poll() {
    local expr="$1"; shift
    out="$(PATH="$FAKE/bin:$PATH" HOME="$FAKE/home" AGENT_TRACKER_HOME="$LOCAL" JR_MACHINE_NAME=mac python3 -c "
import sys
sys.path.insert(0, '$SRC_DIR')
import claude_quota_api_poller as poll_claude
poll_claude.fetch_token = lambda *a: ('dummy', None)
poll_claude.fetch_usage = lambda token: $expr
poll_claude.main(sys.argv[1:])
" "$@" 2>/dev/null)"
    echo "$? $(printf '%s\n' "$out" | tail -n 1)"
}
READING="({'five_hour': {'utilization': 42.0}, 'seven_day': {'utilization': 18}}, {}, None)"
NEVER="(_ for _ in ()).throw(AssertionError('must not poll'))"

section "exit codes and last lines (read by claude-quota.sh)"
assert_eq "a reading -> 0, its summary last" "0 5h 42% · 7d 18%" "$(poll "$READING")"
assert_eq "...the reading names its machine, in raw and in the column" "mac	mac" \
    "$(local_db "SELECT machine, json_extract(raw, '$.machine') FROM account_quotas ORDER BY rowid DESC LIMIT 1")"
assert_eq "429 -> 75, retry-after last" "75 retry-after 1820" \
    "$(poll "(None, None, {'stage': 'http', 'type': 'HTTPError', 'status': 429, 'retry_after_s': 1820})")"
assert_eq "429 without Retry-After -> retry-after 0" "75 retry-after 0" "$(poll "(None, None, {'stage': 'http', 'type': 'HTTPError', 'status': 429})")"
assert_eq "401 -> 1" "1 failed: http HTTPError 401" "$(poll "(None, None, {'stage': 'http', 'type': 'HTTPError', 'status': 401})")"
assert_eq "network error -> 1" "1 failed: network URLError" "$(poll "(None, None, {'stage': 'network', 'type': 'URLError'})")"

section "--if-older-than: no poll while the newest reading is younger"
assert_match "the reading above is seconds old: exit 10, its age" "$(poll "$NEVER" --if-older-than=110)" "^10 quota fresh enough \([0-9]+ s\)$"
assert_eq "older than 0 s: polls" "0 5h 42% · 7d 18%" "$(poll "$READING" --if-older-than=0)"

# ---------------------------------------------------------------- several accounts (2026-11-19)
section "several accounts: each polled with its own token, freshness and 429 wait; another account never fails the run"
UA="11111111-1111-4111-8111-111111111111"; UB="22222222-2222-4222-8222-222222222222"
MA="$(mktemp -d "${TMPDIR:-/tmp}/th-multi.XXXXXX")"
trap 'rm -rf "$MA"' EXIT
mkdir -p "$MA/home/.claude/account-b" "$MA/rt"
echo '{"oauthAccount":{"organizationUuid":"'$UA'"}}' > "$MA/home/.claude.json"
echo '{"oauthAccount":{"organizationUuid":"'$UB'"}}' > "$MA/home/.claude/account-b/.claude.json"
# multi <a's fetch result> <b's fetch result> [poller args...] -> "<exit> <last line>"; the runtime ($MA/rt) is kept between calls
multi() {
    local fa="$1" fb="$2"; shift 2
    HOME="$MA/home" AGENT_TRACKER_HOME="$MA/rt" JR_MACHINE_NAME=mac python3 -c "
import sys
sys.path.insert(0, '$SRC_DIR')
import claude_quota_api_poller as p
p.fetch_token = lambda cd=None: ('tok-b' if cd and cd.endswith('account-b') else 'tok-a', None)
res = {'tok-a': $fa, 'tok-b': $fb}
p.fetch_usage = lambda token: res[token]
sys.argv = ['x'] + sys.argv[1:]
try:
    p.main()
except SystemExit as e:
    sys.stdout.flush(); print('::exit', e.code)
finally:
    p.offer_latest()
" "$@" 2>/dev/null | awk '/::exit/ {code=$2} !/::exit/ {line=$0} END {print code, line}'
}
mq() { python3 -c "import sqlite3, sys
for r in sqlite3.connect('$MA/rt/data/claude/account_quotas.db').execute(sys.argv[1]): print('\t'.join(str(v) for v in r))" "$1"; }
OKA="({'five_hour': {'utilization': 10.0, 'resets_at': '2099-01-01T00:00:00+00:00'}, 'seven_day': {'utilization': 50.0, 'resets_at': '2099-01-01T00:00:00+00:00'}}, {}, None)"
OKB="({'five_hour': {'utilization': 3.0, 'resets_at': '2099-01-01T00:00:00+00:00'}, 'seven_day': {'utilization': 20.0, 'resets_at': '2099-01-01T00:00:00+00:00'}}, {}, None)"
E401="(None, None, {'stage': 'http', 'type': 'HTTPError', 'status': 401})"
E429="(None, None, {'stage': 'http', 'type': 'HTTPError', 'status': 429, 'retry_after_s': 600})"

assert_eq "both read: success, the main account's summary first" "0 5h 10% · 7d 50% · b 5h 3% · 7d 20%" "$(multi "$OKA" "$OKB")"
assert_eq "...one reading per account, each with its organization uuid" "$UA	claude_api
$UB	claude_api" "$(mq "SELECT account, source FROM account_quotas ORDER BY ts, rowid")"
assert_eq "...the accounts table names them" "a	$UA	1
b	$UB	0" "$(mq "SELECT name, org_uuid, is_main FROM accounts ORDER BY name")"
assert_eq "...latest is the main account's, latest_by_account has both" "50.0	2" "$(mq "SELECT (SELECT seven_day_pct FROM latest), (SELECT COUNT(*) FROM latest_by_account)")"
assert_eq "...the main account's quota file" "50" "$(jq -r '.seven_day.used_percentage' "$MA/rt/data/claude/quota_latest.json")"
assert_eq "...b's own file, with its name and uuid" "20 b $UB" "$(jq -r '"\(.seven_day.used_percentage) \(.account_name) \(.account)"' "$MA/rt/data/claude/quota_latest.b.json")"
assert_eq "...the cache tick reads" "a b" "$(jq -r '.accounts | to_entries | map(.value.name) | join(" ")' "$MA/rt/data/claude/accounts.json")"

assert_eq "b's 401 does not fail the run" "0 5h 10% · 7d 50% · b failed: http HTTPError 401" "$(multi "$OKA" "$E401")"
assert_eq "...it is a failed attempt of b's, not a reading" "1" "$(mq "SELECT COUNT(*) FROM poll_errors WHERE raw LIKE '%\"account\": \"$UB\"%'")"
assert_eq "a's 401 fails it" "1 failed: http HTTPError 401 · b 5h 3% · 7d 20%" "$(multi "$E401" "$OKB")"

assert_eq "a 429, b read: the run goes on (exit 0)" "0 retry-after 600 · b 5h 3% · 7d 20%" "$(multi "$E429" "$OKB")"
assert_eq "...a waits (no poll of a), b is polled again" "0 429 wait" "$(multi "$OKA" "$OKB" | cut -c1-10)"
assert_eq "...exit 0 because b was read, a's wait in the line" "0 429 wait" "$(multi "$OKA" "$OKB" | cut -c1-10)"
rm -f "$MA/rt/state/sync/claude_quota_wait.json"
assert_eq "a 429 and no other account read: 75, retry-after last" "75 retry-after 600" "$(multi "$E429" "$E401")"
assert_eq "...nothing kept here: the job's WAIT holds a back (a polled again at once)" "75 retry-after 600" "$(multi "$E429" "$E401")"
rm -f "$MA/rt/state/sync/claude_quota_wait.json"

assert_match "freshness per account: all fresh, exit 10" "$(multi "$OKA" "$OKB" --if-older-than=99999)" "^10 quota fresh enough"
python3 -c "import sqlite3; db = sqlite3.connect('$MA/rt/data/claude/account_quotas.db'); db.execute(\"UPDATE account_quotas SET ts = ts - 1000 WHERE account = '$UB'\"); db.commit()"
assert_eq "b's reading is old, a's is young: only b polled (a skipped: exit 0 because b was read)" "0" "$(multi "$OKA" "$OKB" --if-older-than=500 | cut -d' ' -f1)"

section "an account folder not logged in yet is not polled"
mkdir -p "$MA/home/.claude/account-c"; echo '{}' > "$MA/home/.claude/account-c/.claude.json"
python3 -c "import sqlite3; db = sqlite3.connect('$MA/rt/data/claude/account_quotas.db'); db.execute('DELETE FROM poll_errors'); db.commit()"
multi "$OKA" "$OKB" > /dev/null
assert_eq "no failed attempt, no row for c" "0" "$(mq "SELECT COUNT(*) FROM poll_errors WHERE raw LIKE '%account_name\": \"c%'")"
rm -r "$MA/home/.claude/account-c"

section "--sync-with: each machine's own readings, both ways, in one ssh call"
# The VM's own reading (1 s after the Mac's, so it is the newest), and one from before 2026-10-10
# (no machine in raw; labelled by the migration).
sleep 1
JR_MACHINE_NAME=vm AGENT_TRACKER_HOME="$PEER" python3 -c "
import sys, time; sys.path.insert(0, '$SRC_DIR')
import ingest_account_quota as g, usage_db
db = usage_db.open_account('claude')
g.add_row(db, 'claude', {'ts': int(time.time()), 'source': 'claude_api', 'machine': 'vm', 'api': {'five_hour': {'utilization': 50.0}}})
g.add_row(db, 'claude', {'ts': int(time.time()) - 900, 'source': 'claude_api', 'api': {'five_hour': {'utilization': 49.0}}}, machine='vm')"
mac_before="$(local_db "SELECT COUNT(*) FROM account_quotas")"
assert_eq "fresh: no poll, the sync said in the last line" "10 quota fresh enough (5 s) · sync ↑$mac_before ↓2" \
    "$(poll "$NEVER" --sync-with=vm --sync-every=110 --if-older-than=99999 | sed -E 's/\(-?[0-9]+ s\)/(5 s)/')"
assert_eq "the VM got the Mac's readings, labelled mac" "$mac_before" "$(peer_db "SELECT COUNT(*) FROM account_quotas WHERE machine = 'mac'")"
assert_eq "the Mac got the VM's two, labelled vm, the old one included" "2" "$(local_db "SELECT COUNT(*) FROM account_quotas WHERE machine = 'vm'")"
assert_eq "the same rows on both sides (row_hash)" "$(peer_db "SELECT group_concat(row_hash) FROM (SELECT row_hash FROM account_quotas ORDER BY row_hash)")" \
    "$(local_db "SELECT group_concat(row_hash) FROM (SELECT row_hash FROM account_quotas ORDER BY row_hash)")"
assert_eq "the Mac's latest is the VM's fresher reading" "vm	50.0" "$(local_db "SELECT machine, five_hour_pct FROM latest")"
assert_match "watermarks saved" "$(cat "$LOCAL/state/sync/claude_quotas.json")" '"sent": [0-9]+, "received": [0-9]+, "last_ok_ts": [0-9]+'
assert_eq "not due yet (110 s): no sync" "10 quota fresh enough (5 s)" \
    "$(poll "$NEVER" --sync-with=vm --sync-every=110 --if-older-than=99999 | sed -E 's/\(-?[0-9]+ s\)/(5 s)/')"
assert_match "due again: nothing new either way, nothing echoed back" "$(poll "$NEVER" --sync-with=vm --sync-every=0 --if-older-than=99999)" "· sync ↑0 ↓0$"
peer_before="$(peer_db "SELECT COUNT(*) FROM account_quotas")"
poll "({'five_hour': {'utilization': 43.0}}, {}, None)" --sync-with=vm --sync-every=110 >/dev/null   # 43: not the same row as a poll of the same second
assert_eq "a new Mac reading waits for the next sync" "$peer_before" "$(peer_db "SELECT COUNT(*) FROM account_quotas")"
poll "$NEVER" --sync-with=vm --sync-every=0 --if-older-than=99999 >/dev/null
assert_eq "...and then goes" "$((peer_before + 1))" "$(peer_db "SELECT COUNT(*) FROM account_quotas")"

section "--sync-with: the VM unreachable"
assert_match "the run goes on, the summary says so" "$(PEER_HOME=down poll "$NEVER" --sync-with=vm --sync-every=0 --if-older-than=99999)" "^10 .* · vm not reached$"
assert_eq "...and polls when needed" "0 5h 42% · 7d 18% · vm not reached" "$(PEER_HOME=down poll "$READING" --sync-with=vm --sync-every=0)"
python3 -c "
import json, sys; p = sys.argv[1]; d = json.load(open(p)); d['last_ok_ts'] -= 1800; json.dump(d, open(p, 'w'))" "$LOCAL/state/sync/claude_quotas.json"
assert_match "unreachable for 30 min: a failure" "$(PEER_HOME=down poll "$NEVER" --sync-with=vm --sync-every=0 --if-older-than=99999)" "^1 .* · vm not reached$"
assert_eq "a 429 still waits, its seconds last" "75 vm not reached · retry-after 60" \
    "$(PEER_HOME=down poll "(None, None, {'stage': 'http', 'status': 429, 'retry_after_s': 60})" --sync-with=vm --sync-every=0)"

harness_summary
