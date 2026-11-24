#!/bin/bash
# Tests for src/aggregate_slots.py and its gate src/ingest_aggregates.py
# (Category 3, doc/design.md §6): final slots only, transcript
# requests with telemetry's cost, telemetry-only requests in their session's
# folder with cache writes of unknown duration, tokens_without_usd, each slot
# written once, the gate's checks. Fixture rows only; no transcript is read.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-usage-tracker-slots.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
RT="$TMP/rt"
ADB="$RT/data/claude/aggregates/m1.db"
export AGENT_TRACKER_HOME="$RT" JR_MACHINE_NAME=m1 AGENT_TRACKER_USER_HOME=/Users/x   # this machine's home: the fixtures' folders are its own
S1=11111111-1111-1111-1111-111111111111 S2=22222222-2222-2222-2222-222222222222 SX=99999999-9999-9999-9999-999999999999

py() { python3 -c "import sys; sys.path.insert(0, '$REPO_ROOT/src'); import usage_db, ingest_session_usage as s, ingest_aggregates as g, aggregate_slots as a; $1"; }
q() { python3 -c 'import sqlite3, sys
for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2]):
    print("\t".join("" if v is None else str(v) for v in r))' "$ADB" "$1"; }
# req <ts> <id> <session> <folder> <entrypoint> <model> <in> <out> <cache read> <write 5m> <write 1h>: an intermediary request
req() { py "db = usage_db.open_intermediary('claude'); db.execute('INSERT INTO requests VALUES (?,?,?,?,?,?,?,?,?,?,?,?)', ($1, usage_db.iso($1), '$2', '$3', '$4', '$5', '$6', $7, $8, $9, ${10}, ${11}))"; }
# tel <ts> <request id> <session> <model> <in> <out> <cache read> <cache creation> <cost or None> [job] [account]: a telemetry
# event; with a job, the resource attribute job.name job-runner gives every program a job starts
tel() { py "db = usage_db.open_sessions('claude'); s.add_telemetry(db, {'source': 'claude_otel', 'observed_at': $1, 'received_at': $1, 'event': 'api_request', 'resource': {'service.name': 'claude-code', **({'job.name': '${10:-}'} if '${10:-}' else {})}, 'attributes': {'session.id': '$3', 'request_id': '$2', 'model': '$4', **({'organization.id': '${11:-}'} if '${11:-}' else {}), 'input_tokens': $5, 'output_tokens': $6, 'cache_read_tokens': $7, 'cache_creation_tokens': $8, **({} if '$9' == 'None' else {'cost_usd': $9})}})"; }
scan() { py "db = usage_db.open_intermediary('claude'); db.execute('INSERT INTO scans VALUES (?,?,?,0)', ($1, usage_db.iso($1), $2))"; }
# run <now>: one run, without reading transcripts
run() { py "import time; a.transcript_reader.main = lambda: ''; time.time = lambda: $1; a.main()"; }
COLS="ts, folder, entrypoint, job, model, requests, input_tokens, output_tokens, cache_read_tokens, cache_write_5m_tokens, cache_write_1h_tokens, cache_write_unknown_tokens, ROUND(usd, 4), tokens_without_usd"

req 1000 r1 $S1 /a cli opus 1 10 100 5 7
req 1100 r2 $S1 /a cli opus 2 20 200 0 0
req 1300 r3 $S2 /b sdk-py sonnet 3 30 300 0 0
req 2000 r4 $S1 /a cli opus 4 40 400 0 0
tel 1010 r1 $S1 opus 1 10 100 12 0.5
tel 1010 r1 $S1 opus 1 10 100 12 0.5     # a batch Claude Code sent twice: counted once
tel 1310 r3 $S2 sonnet 3 30 300 0 0.25 jobs.apply   # S2 was started by the job jobs.apply
tel 1150 t1 $S1 haiku 4 40 400 30 0.1    # telemetry only (a title): the folder of its session
tel 1250 t2 $SX haiku 5 50 500 0 None    # telemetry only, a session without transcript, no cost
scan 1950 1900

section "the final slots: those ended by the scan's complete_through"
assert_contains "three slots in two final 5-min slots (900, 1200); 1500 is empty, 1800 not final" "$(run 2000)" "slots: 4 written"
assert_eq "per (slot, folder, entrypoint, job, model); job '' = no job" "900	/a	cli		haiku	1	4	40	400	0	0	30	0.1	0
900	/a	cli		opus	2	3	30	300	5	7	0	0.5	222
1200				haiku	1	5	50	500	0	0	0		555
1200	/b	sdk-py	jobs.apply	sonnet	1	3	30	300	0	0	0	0.25	0" "$(q "SELECT $COLS FROM slots ORDER BY ts, model")"
assert_eq "machine, dt, written_ts" "m1	1970-01-01T00:15:00Z	2000" "$(q "SELECT DISTINCT machine, dt, written_ts FROM slots WHERE ts = 900")"

section "each slot written once; later slots when they become final"
assert_contains "nothing new: nothing written" "$(run 2100)" "slots: 0 written"
scan 2500 2400
assert_contains "the 1800 slot once final" "$(run 2500)" "slots: 1 written"
assert_eq "...with r4" "1800	/a	cli		opus	1	4	40	400	0	0	0		444" "$(q "SELECT $COLS FROM slots WHERE ts = 1800")"
assert_eq "no slot twice" "5" "$(q "SELECT COUNT(*) FROM slots")"

section "the job: one job's session, its subagent and its telemetry-only requests under its name; another job apart"
req 2700 r5 $S2 /b sdk-py sonnet 1 1 0 0 0          # S2 again (the job jobs.apply): no job.name on this request's event
req 2710 r6 $S2 /b sdk-py sonnet 1 1 0 0 0          # a subagent of S2: same session id
S3=33333333-3333-3333-3333-333333333333
req 2720 r7 $S3 /b sdk-py sonnet 1 1 0 0 0          # another job, same folder, entrypoint and model
tel 2721 r7 $S3 sonnet 1 1 0 0 0.01 tasks.launch
tel 2730 t3 $S2 haiku 1 1 0 0 0.02                  # a title of S2, telemetry only
req 2740 r8 $S1 /b sdk-cli sonnet 1 1 0 0 0         # claude -p started by hand: no job
scan 3100 3000
run 3100 >/dev/null
assert_eq "per job, the same folder" "2700	/b	sdk-cli		sonnet	1
2700	/b	sdk-py	jobs.apply	haiku	1
2700	/b	sdk-py	jobs.apply	sonnet	2
2700	/b	sdk-py	tasks.launch	sonnet	1" "$(q "SELECT ts, folder, entrypoint, job, model, requests FROM slots WHERE ts = 2700 ORDER BY entrypoint, job, model")"

section "the gate"
good="dict(ts=600, dt=usage_db.iso(600), machine='m1', folder='', entrypoint='', job='', model='x', requests=1, input_tokens=1, output_tokens=1, cache_read_tokens=0, cache_write_5m_tokens=0, cache_write_1h_tokens=0, cache_write_unknown_tokens=0, usd=None, tokens_without_usd=2, written_ts=1)"
assert_eq "a valid slot" "1" "$(py "print(g.add_slots(usage_db.open_aggregates('claude'), [$good]))")"
assert_eq "the same slot again: a no-op" "0" "$(py "print(g.add_slots(usage_db.open_aggregates('claude'), [$good]))")"
assert_contains "rejected: a slot of another machine (one file per machine)" "$(py "g.add_slots(usage_db.open_aggregates('claude'), [$good | dict(machine='m2')])" 2>&1)" "a slot of 'm2' in the file of 'm1'"
assert_eq "...while m2's own file takes it" "1" "$(py "print(g.add_slots(usage_db.open_aggregates('claude', machine='m2'), [$good | dict(machine='m2')]))")"
for bad in "ts=601" "dt='x'" "machine='a b'" "requests=-1" "usd='1'" "job=None" "five_hour_pct=3"; do
    assert_contains "rejected: $bad" "$(py "g.add_slots(usage_db.open_aggregates('claude'), [$good | dict($bad)])" 2>&1)" "ValueError"
done
assert_eq "a slot from a sender older than job: job ''" "1
[]" \
    "$(py "d = $good; del d['job']; print(g.add_slots(usage_db.open_aggregates('claude'), [d | dict(ts=900, dt=usage_db.iso(900))]))"; q "SELECT '[' || job || ']' FROM slots WHERE ts = 900 AND model = 'x'")"
assert_eq "a bad row rejects its whole batch" "11" \
    "$(py "
try: g.add_slots(usage_db.open_aggregates('claude'), [$good | dict(ts=3000, dt=usage_db.iso(3000)), $good | dict(ts=3001)])
except ValueError: pass" ; q "SELECT COUNT(*) FROM slots")"

section "the account: a request's own telemetry, else its session's account at its time (2026-11-24), else '' (unknown)"
UA=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa UB=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
S4=44444444-4444-4444-4444-444444444444 S5=55555555-5555-5555-5555-555555555555 S6=66666666-6666-6666-6666-666666666666
req 4000 q1 $S4 /c cli opus 1 1 0 0 0
tel 4001 q1 $S4 opus 1 1 0 0 0.1 "" $UA           # its own telemetry names account A
req 4010 q2 $S4 /c cli opus 1 1 0 0 0             # no telemetry of its own: its session has one account (A)
req 4020 q3 $S5 /c cli opus 1 1 0 0 0
tel 4021 q3 $S5 opus 1 1 0 0 0.1 "" $UB
req 4030 q4 $S5 /c cli opus 1 1 0 0 0
tel 4031 q4 $S5 opus 1 1 0 0 0.1 "" $UA           # S5 was resumed on another account: two accounts in one session
req 4040 q5 $S5 /c cli opus 1 1 0 0 0             # no telemetry of its own, its session has two: the one in use then (A, since 4031)
tel 4050 t4 $S4 haiku 1 1 0 0 0.1 "" $UA          # telemetry only, account A
req 4060 q6 $S6 /d cli opus 1 1 0 0 0             # a session telemetry never saw
scan 4600 4500
run 4600 >/dev/null
assert_eq "per account: own telemetry, else the session's account at the time (a session with two included); unknown ''" "/c	haiku	aaaa	1
/c	opus	aaaa	4
/c	opus	bbbb	1
/d	opus		1" "$(q "SELECT folder, model, substr(account, 1, 4), requests FROM slots WHERE ts = 3900 ORDER BY folder, model, account")"
assert_eq "the account is the whole organization uuid" "$UA" "$(q "SELECT DISTINCT account FROM slots WHERE account LIKE 'aaaa%'")"
assert_eq "two accounts, same slot, folder, entrypoint, job and model: two rows (the key holds the account)" "2" "$(q "SELECT COUNT(*) FROM slots WHERE ts = 3900 AND folder = '/c' AND model = 'opus'")"

section "the gate and the account"
OLDDB="$RT/data/claude/aggregates/m3.db"
python3 - "$OLDDB" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript("""CREATE TABLE slots (ts INTEGER NOT NULL, dt TEXT NOT NULL, machine TEXT NOT NULL, folder TEXT NOT NULL,
  entrypoint TEXT NOT NULL, job TEXT NOT NULL DEFAULT '', model TEXT NOT NULL, requests INTEGER NOT NULL, input_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL, cache_read_tokens INTEGER NOT NULL, cache_write_5m_tokens INTEGER NOT NULL,
  cache_write_1h_tokens INTEGER NOT NULL, cache_write_unknown_tokens INTEGER NOT NULL, usd REAL,
  tokens_without_usd INTEGER NOT NULL, written_ts INTEGER NOT NULL, UNIQUE (ts, machine, folder, entrypoint, job, model));
PRAGMA user_version = 4;""")
db.commit()
PY
good3="dict(ts=600, dt=usage_db.iso(600), machine='m3', folder='', entrypoint='', job='', account='', model='x', requests=1, input_tokens=1, output_tokens=1, cache_read_tokens=0, cache_write_5m_tokens=0, cache_write_1h_tokens=0, cache_write_unknown_tokens=0, usd=None, tokens_without_usd=3, written_ts=1)"
assert_eq "a file not migrated yet takes a row that knows no account (it fits the old key)" "1" "$(py "print(g.add_slots(usage_db.open_aggregates('claude', machine='m3'), [$good3]))")"
assert_contains "...and refuses one that knows an account, saying to migrate (it would collide with another account's row)" "$(py "g.add_slots(usage_db.open_aggregates('claude', machine='m3'), [$good3 | dict(ts=900, dt=usage_db.iso(900), account='$UA')])" 2>&1)" "slots-account"
assert_eq "a sender older than the column: account ''" "[]" "$(py "d = $good3 | dict(machine='m1', ts=1500, dt=usage_db.iso(1500)); del d['account']; g.add_slots(usage_db.open_aggregates('claude'), [d])"; q "SELECT '[' || account || ']' FROM slots WHERE ts = 1500 AND model = 'x'")"
assert_eq "a valid uuid is stored" "$UA" "$(py "g.add_slots(usage_db.open_aggregates('claude'), [$good3 | dict(machine='m1', ts=1800, dt=usage_db.iso(1800), account='$UA')])"; q "SELECT account FROM slots WHERE ts = 1800 AND model = 'x'")"
for bad in "account='nope'" "account=None" "account=3"; do
    assert_contains "rejected: $bad" "$(py "g.add_slots(usage_db.open_aggregates('claude'), [$good3 | dict(machine='m1', ts=2100, dt=usage_db.iso(2100), $bad)])" 2>&1)" "ValueError"
done

section "end to end: transcript files -> transcript_reader -> intermediary/ -> slots, with telemetry's cost"
E2E="$TMP/e2e"
mkdir -p "$E2E/projects/-Users-x-dev-app"
# One request streamed over three lines (the largest output counts), one in a later slot, and a resumed copy of the first.
{
    printf '%s\n' '{"type":"assistant","timestamp":"2026-10-08T12:00:00.000Z","requestId":"req_a","sessionId":"'$S1'","cwd":"/Users/x/dev/app","entrypoint":"cli","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"output_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":20}}}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2026-10-08T12:00:02.000Z","requestId":"req_a","sessionId":"'$S1'","cwd":"/Users/x/dev/app","entrypoint":"cli","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"output_tokens":500,"cache_read_input_tokens":100,"cache_creation_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":20}}}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2026-10-08T12:06:00.000Z","requestId":"req_b","sessionId":"'$S1'","cwd":"/Users/x/dev/app","entrypoint":"cli","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":7,"cache_read_input_tokens":50,"cache_creation_input_tokens":0}}}'
} > "$E2E/projects/-Users-x-dev-app/s1.jsonl"
mkdir -p "$E2E/projects/-Users-x-dev-app2" && head -2 "$E2E/projects/-Users-x-dev-app/s1.jsonl" > "$E2E/projects/-Users-x-dev-app2/resumed.jsonl"
e2e() {   # e2e <epoch>: one aggregates run at that time, on the fixture transcripts
    AGENT_TRACKER_HOME="$E2E/rt" AGENT_USAGE_TRACKER_TRANSCRIPTS="$E2E/projects" AGENT_USAGE_TRACKER_CODEX_SESSIONS="$E2E/none" \
        python3 -c "import sys, time; sys.path.insert(0, '$REPO_ROOT/src'); time.time = lambda: $1; import aggregate_slots as a; a.main()"
}
AGENT_TRACKER_HOME="$E2E/rt" python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/src'); import usage_db, ingest_session_usage as s
s.add_telemetry(usage_db.open_sessions('claude'), {'source': 'claude_otel', 'observed_at': 1791460805, 'received_at': 1791460806, 'event': 'api_request',
    'attributes': {'session.id': '$S1', 'request_id': 'req_a', 'model': 'claude-opus-5-5', 'cost_usd': 0.0123}})"
T0=1791460800   # 2026-10-08T12:00:00Z
out="$(e2e $((T0 + 900 + 400)))"   # 12:21:40: complete through 12:06:40, so the 12:00 slot is final, 12:05 not yet
assert_contains "the reader read both requests (req_b started before 12:06:40), the resumed copy skipped" "$out" "requests added 2"
assert_contains "...but wrote only the final slot, 12:00" "$out" "slots: 1 written"
ADB_E2E="$E2E/rt/data/claude/aggregates/m1.db"
assert_eq "12:00: req_a once (resumed copy skipped), its largest output, 5m / 1h split, telemetry's cost" \
    "1791460800	/Users/x/dev/app	cli	claude-opus-5-5	1	2	500	100	10	20	0	0.0123	0" \
    "$(python3 -c 'import sqlite3, sys
for r in sqlite3.connect(sys.argv[1]).execute("SELECT ts, folder, entrypoint, model, requests, input_tokens, output_tokens, cache_read_tokens, cache_write_5m_tokens, cache_write_1h_tokens, cache_write_unknown_tokens, usd, tokens_without_usd FROM slots"):
    print("\t".join("" if v is None else str(v) for v in r))' "$ADB_E2E")"
e2e $((T0 + 3600)) >/dev/null
assert_eq "an hour later: req_b's slot, without telemetry: no usd, all its tokens without" "1791461100		58" \
    "$(python3 -c 'import sqlite3, sys
for r in sqlite3.connect(sys.argv[1]).execute("SELECT ts, usd, tokens_without_usd FROM slots WHERE ts > 1791460800"):
    print("\t".join("" if v is None else str(v) for v in r))' "$ADB_E2E")"

harness_summary
