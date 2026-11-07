#!/bin/bash
# Tests for `agent-tracker` (src/agent_tracker.py): tick, hook start|end, now,
# check, last-seen-age, and quota_latest.json from the statusline and the
# pollers. All in a sandbox: its own HOME, CLAUDE_CONFIG_DIR, AGENT_TRACKER_HOME
# and tmux server (TMUX_TMPDIR; harness.sh unsets TMUX / TMUX_PANE first, so
# the tmux of the shell running the tests is never reached). A fake Claude
# Code is a bash process started here: it writes its own
# $CLAUDE_CONFIG_DIR/sessions/<pid>.json, runs the hook and a tick as its
# children, then becomes a `sleep` (same pid, same start time); the test kills
# only those.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

S="$(mktemp -d "${TMPDIR:-/tmp}/agent-tracker-cmd.XXXXXX")"
# tmux's socket path must stay under ~104 bytes: its folder is a short one.
TMUX_DIR="$(mktemp -d "${AGENT_TRACKER_TEST_SHORT_TMP:-/tmp}/att.XXXXXX")"
export HOME="$S/home" CLAUDE_CONFIG_DIR="$S/home/.claude" AGENT_TRACKER_HOME="$S/home/opt/agent-tracker" \
    TMUX_TMPDIR="$TMUX_DIR" JR_MACHINE_NAME=test-machine
mkdir -p "$CLAUDE_CONFIG_DIR/sessions" "$CLAUDE_CONFIG_DIR/projects/-work" "$TMUX_TMPDIR"
AT="$REPO_ROOT/src/agent_tracker.py"
DATA="$AGENT_TRACKER_HOME/data"
L_PIDS=()
cleanup() {
    for pid in "${L_PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
    tmux kill-server 2>/dev/null
    rm -rf "$S" "$TMUX_DIR"
}
trap cleanup EXIT
at() { python3 "$AT" "$@"; }
jqf() { jq -r "$1" "$2" 2>/dev/null; }

# A transcript: a prompt (10:00), an answer (10:01), a tool result (10:02, not a prompt), an answer (10:03).
TRANSCRIPT="$CLAUDE_CONFIG_DIR/projects/-work/u1.jsonl"
{
    printf '%s\n' '{"type":"user","timestamp":"2026-11-07T10:00:00Z","message":{"role":"user","content":"fix the tests please"}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2026-11-07T10:01:00Z","message":{"content":[]}}'
    printf '%s\n' '{"type":"user","timestamp":"2026-11-07T10:02:00Z","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2026-11-07T10:03:00Z","message":{"content":[]}}'
} > "$TRANSCRIPT"
T_PROMPT=1794045600   # 2026-11-07T10:00:00Z
T_ANSWER=1794045780   # 2026-11-07T10:03:00Z
# payload FILE UUID [CWD] [TRANSCRIPT]: the statusline fixture, made this Claude session's.
payload() {
    jq -c --arg u "$2" --arg c "${3:-/work}" --arg t "${4:-$TRANSCRIPT}" \
        '.session_id = $u | .cwd = $c | .transcript_path = $t' "$TESTS_DIR/fixtures/statusline_payload.claude.json" > "$1"
}
payload "$S/p1.json" u1
payload "$S/p2.json" u2 /work/two

# The fake Claude Code: fake_claude.sh UUID PAYLOAD [KIND] - its live file, the SessionStart hook, one tick, then sleep.
cat > "$S/fake_claude.sh" <<'EOF'
uuid=$1 payload=$2 kind=${3:-interactive}
printf '{"pid":%d,"sessionId":"%s","kind":"%s","status":"idle","cwd":"/work"}\n' $$ "$uuid" "$kind" > "$CLAUDE_CONFIG_DIR/sessions/$$.json"
printf '{"session_id":"%s","transcript_path":"x","cwd":"/work","hook_event_name":"SessionStart","source":"startup"}' "$uuid" \
    | python3 "$AT" hook start > "$S/hook-out-$uuid"
python3 "$AT" tick < "$payload" > "$S/tick-out-$uuid"
echo $$ > "$S/ready-$uuid"
exec sleep 600
EOF
wait_ready() { local i; for i in $(seq 1 100); do [ -s "$S/ready-$1" ] && return 0; sleep 0.1; done; return 1; }
export AT S

# ---------------------------------------------------------------- tick, in a tmux pane
section "tick in a tmux pane: stdout is stdin, last_seen.json has every field"
tmux new-session -d -s work -x 200 -y 50 -n editor "bash $S/fake_claude.sh u1 $S/p1.json"
wait_ready u1
assert_status "the fake Claude session ran its tick" 0 $?
PID1="$(cat "$S/ready-u1")"; L_PIDS+=("$PID1")
cmp -s "$S/p1.json" "$S/tick-out-u1"
assert_status "stdout is stdin, byte for byte" 0 $?
SEEN="$DATA/sessions/u1/last_seen.json"
assert_eq "ts and dt first, in the contract's order" \
    "ts dt agent machine boot_ts uuid pid pid_start tmux_session window_id window_index window_name pane_id pane_index pane window_layout cwd transcript" \
    "$(jq -r 'keys_unsorted | join(" ")' "$SEEN")"
assert_eq "agent" "claude" "$(jqf .agent "$SEEN")"
assert_eq "machine" "test-machine" "$(jqf .machine "$SEEN")"
assert_eq "uuid" "u1" "$(jqf .uuid "$SEEN")"
assert_eq "pid: the fake Claude (the first parent with sessions/<pid>.json)" "$PID1" "$(jqf .pid "$SEEN")"
REAL_START="$(python3 -c "import sys; sys.path.insert(0, '$REPO_ROOT/src'); import agent_tracker as a; print(a.proc_info($PID1)[1])")"
assert_eq "pid_start: that process's start time" "$REAL_START" "$(jqf .pid_start "$SEEN")"
assert_eq "boot_ts: this boot" "$(python3 -c "import sys; sys.path.insert(0, '$REPO_ROOT/src'); import agent_tracker as a; print(a.kernel_boot_ts())")" "$(jqf .boot_ts "$SEEN")"
assert_eq "tmux_session" "work" "$(jqf .tmux_session "$SEEN")"
assert_eq "window_name" "editor" "$(jqf .window_name "$SEEN")"
assert_eq "window_index, pane_index (numbers)" "0 0" "$(jq -r '"\(.window_index) \(.pane_index)"' "$SEEN")"
assert_eq "pane_id" "$(tmux display -p -t work:0.0 '#{pane_id}')" "$(jqf .pane_id "$SEEN")"
assert_eq "window_id" "$(tmux display -p -t work:0.0 '#{window_id}')" "$(jqf .window_id "$SEEN")"
assert_eq "pane" "work:0.0" "$(jqf .pane "$SEEN")"
assert_eq "window_layout: tmux's own" "$(tmux display -p -t work:0.0 '#{window_layout}')" "$(jqf .window_layout "$SEEN")"
assert_eq "cwd from the payload" "/work" "$(jqf .cwd "$SEEN")"
assert_eq "transcript from the payload" "$TRANSCRIPT" "$(jqf .transcript "$SEEN")"
assert_eq "dt is ts in ISO UTC" "$(python3 -c "import time; print(time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime($(jqf .ts "$SEEN"))))")" "$(jqf .dt "$SEEN")"
assert_eq "no temp file left" "last_seen.json lifecycle.jsonl" "$(ls -A "$DATA/sessions/u1" | sort | paste -sd ' ' -)"

section "hook start in the same pane: one line, nothing printed"
LC="$DATA/sessions/u1/lifecycle.jsonl"
assert_eq "printed nothing" "" "$(cat "$S/hook-out-u1")"
assert_eq "one line" "1" "$(wc -l < "$LC" | tr -d ' ')"
assert_eq "its keys" "ts dt event source agent machine boot_ts pid pid_start pane_id pane cwd" "$(head -1 "$LC" | jq -r 'keys_unsorted | join(" ")')"
assert_eq "event start, source startup, agent claude" "start startup claude" "$(head -1 "$LC" | jq -r '"\(.event) \(.source) \(.agent)"')"
assert_eq "its pid and pid_start: the fake Claude's" "$PID1 $REAL_START" "$(head -1 "$LC" | jq -r '"\(.pid) \(.pid_start)"')"
assert_eq "its pane" "$(jqf .pane_id "$SEEN") work:0.0" "$(head -1 "$LC" | jq -r '"\(.pane_id) \(.pane)"')"

section "a second Claude session in a split pane"
tmux split-window -h -t work:editor "bash $S/fake_claude.sh u2 $S/p2.json"
wait_ready u2
PID2="$(cat "$S/ready-u2")"; L_PIDS+=("$PID2")
SEEN2="$DATA/sessions/u2/last_seen.json"
assert_eq "its pane" "work:0.1" "$(jqf .pane "$SEEN2")"
assert_eq "the layout now has two panes, as tmux says" "$(tmux display -p -t work:0.1 '#{window_layout}')" "$(jqf .window_layout "$SEEN2")"
assert_contains "...a split layout" "$(jqf .window_layout "$SEEN2")" "{"

# ---------------------------------------------------------------- the usage recording and quota_latest.json
section "tick records the usage, as statusline_payload_reader.py did, and quota_latest.json"
q() { python3 -c "import sqlite3; print(sqlite3.connect('$DATA/claude/$1').execute(\"$2\").fetchone()[0])"; }
assert_eq "an account reading per Claude session, dated by the transcript's last answer" "2 $T_ANSWER" \
    "$(q account_quotas.db "SELECT COUNT(*) || ' ' || MAX(ts) FROM account_quotas WHERE source = 'claude_statusline'")"
assert_eq "a session snapshot per Claude session" "2" "$(q sessions_usages.db "SELECT COUNT(DISTINCT session_id) FROM session_snapshots")"
QL="$DATA/claude/quota_latest.json"
assert_eq "quota_latest.json: its keys" "ts dt source machine five_hour seven_day" "$(jq -r 'keys_unsorted | join(" ")' "$QL")"
assert_eq "...dated by the reading (observed_at), from the statusline, this machine" "$T_ANSWER statusline test-machine" \
    "$(jq -r '"\(.ts) \(.source) \(.machine)"' "$QL")"
assert_eq "...the windows as Claude Code sends them" '{"used_percentage":55,"resets_at":1788091200} {"used_percentage":70,"resets_at":1788307200}' \
    "$(jq -c '.five_hour, .seven_day' "$QL" | paste -sd ' ' -)"
# An older reading (a transcript whose last answer is 09:00) never replaces it; a newer one does.
printf '%s\n' '{"type":"assistant","timestamp":"2026-11-07T09:00:00Z"}' > "$S/old.jsonl"
jq -c '.transcript_path = $t | .session_id = "u9" | .rate_limits.five_hour.used_percentage = 1' --arg t "$S/old.jsonl" "$S/p1.json" > "$S/p_old.json"
at tick < "$S/p_old.json" > /dev/null
assert_eq "an older reading leaves quota_latest.json as it is" "$T_ANSWER 55" "$(jq -r '"\(.ts) \(.five_hour.used_percentage)"' "$QL")"
printf '%s\n' '{"type":"assistant","timestamp":"2026-11-07T11:00:00Z"}' > "$S/new.jsonl"
jq -c '.transcript_path = $t | .session_id = "u9" | .rate_limits.five_hour.used_percentage = 61.5' --arg t "$S/new.jsonl" "$S/p1.json" > "$S/p_new.json"
at tick < "$S/p_new.json" > /dev/null
assert_eq "a fresher one replaces it (percent unrounded)" "1794049200 61.5" "$(jq -r '"\(.ts) \(.five_hour.used_percentage)"' "$QL")"
# The same ts again (a Claude session reporting a new percent under its last answer's time):
# other values replace it, the same values write nothing.
jq -c '.rate_limits.five_hour.used_percentage = 62' "$S/p_new.json" > "$S/p_tie.json"
at tick < "$S/p_tie.json" > /dev/null
assert_eq "the same ts with another percent replaces it (2026-11-07: 31% kept, 32% refused)" "1794049200 62" \
    "$(jq -r '"\(.ts) \(.five_hour.used_percentage)"' "$QL")"
assert_eq "...the same ts with the same values writes nothing" "False" \
    "$(cd "$REPO_ROOT/src" && python3 -c "
import json, agent_tracker as a
d = json.load(open('$QL'))
print(a.offer_quota('claude', d['ts'], 'statusline', 'other-machine', d['five_hour'], d['seven_day']))")"
jq -c 'del(.rate_limits) | .session_id = "u9"' "$S/p1.json" > "$S/p_nolimits.json"
at tick < "$S/p_nolimits.json" > /dev/null
assert_eq "a payload without rate_limits changes nothing" "1794049200" "$(jqf .ts "$QL")"

section "the quota pollers offer the database's newest reading to quota_latest.json"
python3 - "$REPO_ROOT/src" <<'PY'
import sys, json, time
sys.path.insert(0, sys.argv[1])
import usage_db, ingest_account_quota, agent_tracker
now = int(time.time())
row = {"ts": now, "iso": usage_db.iso(now), "source": "claude_api", "machine": "H-Frank-1",
       "api": {"five_hour": {"utilization": 33.0, "resets_at": "2026-11-07T15:00:00+00:00"},
               "seven_day": {"utilization": 44.0, "resets_at": None}}, "error": None}
ingest_account_quota.add_row(usage_db.open_account("claude"), "claude", row)
print("claude", agent_tracker.offer_quota_from_db("claude"), agent_tracker.offer_quota_from_db("claude"))
row = {"ts": now, "iso": usage_db.iso(now), "source": "codex_app_server", "error": None, "codex_usage": None,
       "codex_rate_limits": {"rateLimits": {"primary": {"usedPercent": 12, "windowDurationMins": 300, "resetsAt": now + 3600},
                                            "secondary": {"usedPercent": 7, "windowDurationMins": 10080, "resetsAt": now + 86400}}}}
ingest_account_quota.add_row(usage_db.open_account("codex"), "codex", row)
print("codex", agent_tracker.offer_quota_from_db("codex"))
PY
assert_eq "claude: a poller reading, fresher, from the VM (synced): written once" "poller H-Frank-1 33 1794063600 44 null" \
    "$(jq -r '"\(.source) \(.machine) \(.five_hour.used_percentage) \(.five_hour.resets_at) \(.seven_day.used_percentage) \(.seven_day.resets_at)"' "$QL")"
assert_eq "codex: its own file, same shape" "poller 12 7" \
    "$(jq -r '"\(.source) \(.five_hour.used_percentage) \(.seven_day.used_percentage)"' "$DATA/codex/quota_latest.json")"
out="$(cd "$REPO_ROOT/src" && JR_MACHINE_NAME=mac python3 -c "
import sys, claude_quota_api_poller as p
p.newest_age = lambda now: 5
sys.argv = ['x', '--if-older-than=100']
try:
    p.main()
except SystemExit as e:
    print('exit', e.code)
finally:
    p.offer_latest()
" 2>&1)"
assert_contains "claude_quota_api_poller: a skip still offers the newest reading, without failing" "$out" "exit 10"

# ---------------------------------------------------------------- the rewrite rule
section "last_seen.json is rewritten only on a change, or once a minute"
# One fake parent for the whole sequence (the same pid throughout); between the ticks it copies the file out.
payload "$S/p3.json" u3 /a; payload "$S/p3b.json" u3 /b
bash -c '
    printf "{\"pid\":%d,\"sessionId\":\"u3\"}" $$ > "$CLAUDE_CONFIG_DIR/sessions/$$.json"
    f="$AGENT_TRACKER_HOME/data/sessions/u3/last_seen.json"
    python3 "$AT" tick < "$S/p3.json" > /dev/null; cp "$f" "$S/r1"
    jq -c ".ts -= 30" "$f" > "$f.x" && mv "$f.x" "$f"
    python3 "$AT" tick < "$S/p3.json" > /dev/null; cp "$f" "$S/r2"
    python3 "$AT" tick < "$S/p3b.json" > /dev/null; cp "$f" "$S/r3"
    jq -c ".ts -= 61" "$f" > "$f.x" && mv "$f.x" "$f"; cp "$f" "$S/r4a"
    python3 "$AT" tick < "$S/p3b.json" > /dev/null; cp "$f" "$S/r4"
    rm -f "$CLAUDE_CONFIG_DIR/sessions/$$.json"' 2>/dev/null
assert_eq "outside tmux: every tmux field is null" "null null null null null null null null" \
    "$(jq -r '[.tmux_session, .window_id, .window_index, .window_name, .pane_id, .pane_index, .pane, .window_layout] | map(tostring) | join(" ")' "$S/r1")"
assert_eq "nothing changed, 30 s old: not rewritten" "$(( $(jqf .ts "$S/r1") - 30 ))" "$(jqf .ts "$S/r2")"
assert_eq "the folder changed: rewritten at once" "/b $(jqf .ts "$S/r1")" "$(jq -r '"\(.cwd) \(.ts)"' "$S/r3")"
assert_ne "unchanged but 61 s old: rewritten" "$(jqf .ts "$S/r4a")" "$(jqf .ts "$S/r4")"

# ---------------------------------------------------------------- tick never fails
section "tick never fails"
out="$(printf 'not json at all' | at tick; echo "rc=$?")"
assert_eq "bad JSON: copied unchanged, exit 0" "not json at allrc=0" "$out"
assert_contains "...the failure logged" "$(cat "$AGENT_TRACKER_HOME/logs/tick-errors.log")" "parsing the payload failed"
printf '\x00\xff\xfe binary\n' > "$S/bin.in"
at tick < "$S/bin.in" > "$S/bin.out"; cmp -s "$S/bin.in" "$S/bin.out"
assert_status "binary input: byte for byte" 0 $?
AGENT_TRACKER_HOME=/dev/null/nowhere python3 "$AT" tick < "$S/p1.json" > "$S/unw.out"; rc=$?
cmp -s "$S/p1.json" "$S/unw.out"
assert_eq "an unwritable runtime: copied unchanged, exit 0" "0 0" "$? $rc"
out="$(printf '{}' | at tick --no-such-flag; echo "rc=$?")"
assert_contains "even a bad flag: exit 0" "$out" "rc=0"
printf '{"session_id":"../../etc"}' | at tick > /dev/null
assert_file_missing "a session_id that is not a folder name writes nothing" "$DATA/etc"

section "tick is fast (< 150 ms)"
payload "$S/p_time.json" u-time
python3 - "$AT" "$S/p_time.json" > "$S/timing" <<'PY'
import subprocess, sys, time
l_ms = []
for _ in range(15):
    t = time.perf_counter()
    subprocess.run([sys.executable, "-S", sys.argv[1], "tick"], stdin=open(sys.argv[2]), stdout=subprocess.DEVNULL)
    l_ms.append((time.perf_counter() - t) * 1000)
l_ms.sort()
print(f"{l_ms[len(l_ms) // 2]:.0f} {l_ms[-1]:.0f}")
PY
read -r median worst < "$S/timing"
printf '      measured: median %s ms, worst %s ms (15 ticks, usage recording included)\n' "$median" "$worst"
[ "$median" -lt 150 ]
assert_status "median under 150 ms" 0 $?

# ---------------------------------------------------------------- hooks
section "hook end, Codex, and a hook never fails"
printf '{"session_id":"u1","reason":"exit"}' | at hook end > "$S/out"; rc=$?
assert_eq "end: prints nothing, exit 0" "0:" "$rc:$(cat "$S/out")"
assert_eq "end line: its keys and reason" "ts dt event reason pid|end exit" \
    "$(tail -1 "$LC" | jq -r '(keys_unsorted | join(" ")) + "|" + .event + " " + .reason')"
printf '{"session_id":"u1"}' | at hook end
assert_eq "end without a reason: other" "other" "$(tail -1 "$LC" | jq -r .reason)"
long="/$(printf 'x%.0s' $(seq 1 700))"
printf '{"session_id":"u5","cwd":"%s","source":"resume"}' "$long" | at hook start
assert_eq "a 700-character folder: the line stays under 512 bytes" "yes" \
    "$([ "$(head -1 "$DATA/sessions/u5/lifecycle.jsonl" | wc -c)" -le 512 ] && echo yes)"
assert_eq "...and is valid JSON with its source" "resume" "$(head -1 "$DATA/sessions/u5/lifecycle.jsonl" | jq -r .source)"
ln -s "$(command -v bash)" "$S/codex"
"$S/codex" -c 'printf "{\"session_id\":\"c1\",\"cwd\":\"/w\",\"source\":\"startup\"}" | python3 "$AT" hook start --agent codex; echo $$ > "$S/codex-pid"'
assert_eq "Codex: agent codex, pid = the nearest process started as codex" "codex $(cat "$S/codex-pid")" \
    "$(head -1 "$DATA/sessions/c1/lifecycle.jsonl" | jq -r '"\(.agent) \(.pid)"')"
# The Remote Control bridge: its live file says entrypoint sdk-cli (kind "interactive"). claude -p:
# no live file yet, its command line has --print. Neither gets a folder, at start or end.
ln -s "$(command -v bash)" "$S/claude"
"$S/claude" -c 'printf "{\"pid\":%d,\"sessionId\":\"u-bridge\",\"kind\":\"interactive\",\"entrypoint\":\"sdk-cli\"}" $$ > "$CLAUDE_CONFIG_DIR/sessions/$$.json"
    for e in start end; do printf "{\"session_id\":\"u-bridge\",\"cwd\":\"/w\"}" | python3 "$AT" hook $e; done; rm "$CLAUDE_CONFIG_DIR/sessions/$$.json"'
assert_eq "an SDK process (the Remote Control bridge): no folder" "no" "$([ -e "$DATA/sessions/u-bridge" ] && echo yes || echo no)"
"$S/claude" -c 'for e in start end; do printf "{\"session_id\":\"u-print\",\"cwd\":\"/w\"}" | python3 "$AT" hook $e; done' x --print
assert_eq "claude --print, before its live file exists: no folder" "no" "$([ -e "$DATA/sessions/u-print" ] && echo yes || echo no)"
"$S/claude" -c 'printf "{\"session_id\":\"u-typed\",\"cwd\":\"/w\"}" | python3 "$AT" hook start' x --model opus
assert_eq "...a conversation started as claude, no live file yet: recorded" "start" \
    "$(jq -r .event "$DATA/sessions/u-typed/lifecycle.jsonl" 2>/dev/null)"
out="$(printf 'garbage' | at hook start; echo "rc=$?")"
assert_eq "bad JSON: nothing printed, exit 0" "rc=0" "$out"
assert_contains "...logged" "$(cat "$AGENT_TRACKER_HOME/logs/hook-errors.log")" "hook start failed"
python3 - "$DATA/sessions/u7/lifecycle.jsonl" "$AT" <<'PY'
# Two hooks at once, 200 lines each: every line whole, none mixed.
import subprocess, sys, os
os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True)
l_procs = [subprocess.Popen(f'for i in $(seq 1 100); do printf \'{{"session_id":"u7","cwd":"/{c}"}}\' | python3 -S {sys.argv[2]} hook start; done',
                            shell=True) for c in ("a" * 300, "b" * 300)]
[p.wait() for p in l_procs]
PY
assert_eq "200 concurrent appends: 200 whole lines" "200 200" \
    "$(wc -l < "$DATA/sessions/u7/lifecycle.jsonl" | tr -d ' ') $(jq -c . "$DATA/sessions/u7/lifecycle.jsonl" 2>/dev/null | wc -l | tr -d ' ')"

# ---------------------------------------------------------------- now
section "now: the open Claude sessions of this boot"
# u1 got two end lines above: it is not open any more; give it a new start (a resume in the same process).
printf '{"ts":1,"dt":"x","event":"start","source":"resume","agent":"claude","machine":"test-machine","boot_ts":%s,"pid":%s,"pid_start":%s,"pane_id":"%s","pane":"work:0.0","cwd":"/work"}\n' \
    "$(jqf .boot_ts "$SEEN")" "$PID1" "$REAL_START" "$(jqf .pane_id "$SEEN")" >> "$LC"
# Hooks run straight from this test (u5, u7) may find the Claude Code running the tests as their
# nearest `claude`, correctly: only the fake ones are asserted on.
OURS='map(select(.uuid | test("^(u1|u2|u3|c1)$"))) | map(.uuid) | join(" ")'
th_run at now --json
assert_status "exit 0" 0 "$TH_STATUS"
assert_eq "two open: u1 and u2 (u3 has no start line, c1's codex exited)" "u1 u2" "$(jq -r "$OURS" <<< "$TH_OUT")"
TH_OUT="$(jq 'map(select(.uuid == "u1" or .uuid == "u2"))' <<< "$TH_OUT")"
assert_eq "--json: exactly the contract's keys, in order" \
    "uuid agent pid pid_start pane_id pane tmux_session window_index pane_index cwd status transcript last_prompt last_seen" \
    "$(jq -r '.[0] | keys_unsorted | join(" ")' <<< "$TH_OUT")"
assert_eq "u1: pid, pid_start, pane, tmux place" "$PID1 $REAL_START work:0.0 work 0 0" \
    "$(jq -r '.[0] | "\(.pid) \(.pid_start) \(.pane) \(.tmux_session) \(.window_index) \(.pane_index)"' <<< "$TH_OUT")"
assert_eq "u1: status from Claude Code's live file" "idle" "$(jq -r '.[0].status' <<< "$TH_OUT")"
assert_eq "u1: last prompt = the last user entry that is not a tool result" "{\"ts\":$T_PROMPT,\"dt\":\"2026-11-07T10:00:00Z\"}" \
    "$(jq -c '.[0].last_prompt' <<< "$TH_OUT")"
assert_eq "u1: last seen = last_seen.json's ts" "$(jq -c '{ts, dt}' "$SEEN")" "$(jq -c '.[0].last_seen' <<< "$TH_OUT")"
assert_eq "u1: transcript, cwd" "$TRANSCRIPT /work" "$(jq -r '.[0] | "\(.transcript) \(.cwd)"' <<< "$TH_OUT")"
assert_eq "u2: its pane and folder" "work:0.1 /work/two" "$(jq -r '.[1] | "\(.pane) \(.cwd)"' <<< "$TH_OUT")"
sed -i.bak 's/"status":"idle"/"status":"busy"/' "$CLAUDE_CONFIG_DIR/sessions/$PID2.json"
assert_eq "status read live: busy now" "busy" "$(at now --uuid u2 --json | jq -r '.[0].status')"
mv "$CLAUDE_CONFIG_DIR/sessions/$PID2.json" "$S/live2.json"
assert_eq "no live file: status null" "null" "$(at now --uuid u2 --json | jq -r '.[0].status')"
mv "$S/live2.json" "$CLAUDE_CONFIG_DIR/sessions/$PID2.json"
PANE2="$(jqf .pane_id "$SEEN2")"
assert_eq "--pane %id: only that one" "u2" "$(at now --pane "$PANE2" --json | jq -r 'map(.uuid) | join(" ")')"
assert_eq "--uuid: only that one" "u1" "$(at now --uuid u1 --json | jq -r 'map(.uuid) | join(" ")')"
tmux rename-session -t work moved
assert_eq "the pane is resolved now, by pane_id: a renamed tmux session shows" "moved:0.0 moved" \
    "$(at now --uuid u1 --json | jq -r '.[0] | "\(.pane) \(.tmux_session)"')"
th_run at now
assert_contains "the table: u1's pane" "$TH_OUT" "moved:0.0"
assert_contains "...its last prompt's text" "$TH_OUT" "fix the tests please"
assert_eq "a reboot (another boot_ts): nothing open" "0" "$(AGENT_TRACKER_BOOT_TS=1 python3 "$AT" now --json | jq length)"
assert_eq "...and with that boot faked as the current one, they are" "u1 u2" \
    "$(AGENT_TRACKER_BOOT_TS="$(jqf .boot_ts "$SEEN")" python3 "$AT" now --json | jq -r "$OURS")"
# A reused pid: the same pid number, another start time.
cp "$DATA/sessions/u2/lifecycle.jsonl" "$S/lc2"
jq -c ".pid_start -= 100" "$S/lc2" > "$DATA/sessions/u2/lifecycle.jsonl"
assert_eq "a pid whose start time differs (reused): not open" "u1" "$(at now --json | jq -r "$OURS")"
cp "$S/lc2" "$DATA/sessions/u2/lifecycle.jsonl"
# A folder written before the rule (the seed of 2026-11-07) for a live SDK process: not listed.
sleep 600 & PID_SDK=$!; L_PIDS+=("$PID_SDK")
printf '{"pid":%d,"sessionId":"u3","kind":"interactive","entrypoint":"sdk-cli"}' "$PID_SDK" > "$CLAUDE_CONFIG_DIR/sessions/$PID_SDK.json"
mkdir -p "$DATA/sessions/u3"
printf '{"ts":1,"dt":"x","event":"start","source":"seed","agent":"claude","boot_ts":%s,"pid":%s,"pid_start":%s,"pane_id":null,"cwd":"/w"}\n' \
    "$(jqf .boot_ts "$SEEN")" "$PID_SDK" "$(cd "$REPO_ROOT/src" && python3 -c "import agent_tracker as a; print(a.proc_info($PID_SDK)[1])")" \
    > "$DATA/sessions/u3/lifecycle.jsonl"
assert_eq "an SDK process with a folder: not in now" "u1 u2" "$(at now --json | jq -r "$OURS")"
kill "$PID_SDK" 2>/dev/null; rm -f "$CLAUDE_CONFIG_DIR/sessions/$PID_SDK.json"
printf '{"ts":1,"dt":"x","event":"start"' >> "$DATA/sessions/u2/lifecycle.jsonl"
assert_eq "a last line without its newline is ignored" "u1 u2" "$(at now --json | jq -r "$OURS")"
cp "$S/lc2" "$DATA/sessions/u2/lifecycle.jsonl"

# ---------------------------------------------------------------- check
section "check: is every writer writing?"
printf '{"statusLine":{"type":"command","command":"agent-tracker tick | bash ~/.claude/statusline-command.sh"},"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"$HOME/.local/bin/agent-tracker hook start"}]}],"SessionEnd":[{"matcher":"","hooks":[{"type":"command","command":"$HOME/.local/bin/agent-tracker hook end"}]}]}}\n' \
    > "$CLAUDE_CONFIG_DIR/settings.json"
printf '{"pid":999999,"sessionId":"dead"}' > "$CLAUDE_CONFIG_DIR/sessions/999999.json"   # left over from a crash
th_run at check
assert_eq "all good: exit 0" "0 all good" "$TH_STATUS $TH_OUT"
jq -c '.ts -= 200' "$SEEN2" > "$S/x" && mv "$S/x" "$SEEN2"
th_run at check
assert_status "a stale last_seen.json: exit 1" 1 "$TH_STATUS"
assert_contains "...names it" "$TH_OUT" "last_seen.json of u2 is"
sleep 600 & L_PIDS+=($!)
printf '{"pid":%d,"sessionId":"u-unknown","kind":"interactive"}' $! > "$CLAUDE_CONFIG_DIR/sessions/$!.json"
sleep 600 & L_PIDS+=($!)
printf '{"pid":%d,"sessionId":"u-batch","kind":"sdk-cli"}' $! > "$CLAUDE_CONFIG_DIR/sessions/$!.json"
mkdir -p "$DATA/sessions/u-batch" && printf '{"event":"start"}\n' > "$DATA/sessions/u-batch/lifecycle.jsonl"
sleep 600 & L_PIDS+=($!)
printf '{"pid":%d,"sessionId":"u-sdk","kind":"interactive","entrypoint":"sdk-cli"}' $! > "$CLAUDE_CONFIG_DIR/sessions/$!.json"
jq '.statusLine.command = "bash ~/.claude/statusline-command.sh" | del(.hooks.SessionEnd)' "$CLAUDE_CONFIG_DIR/settings.json" > "$S/x" \
    && mv "$S/x" "$CLAUDE_CONFIG_DIR/settings.json"
th_run at check
assert_contains "an open Claude session with no folder" "$TH_OUT" "no folder data/sessions/u-unknown/"
assert_not_contains "a claude -p session needs no last_seen.json" "$TH_OUT" "u-batch"
assert_not_contains "an SDK process (the Remote Control bridge) needs no folder" "$TH_OUT" "u-sdk"
assert_contains "the statusLine not chained" "$TH_OUT" "statusLine in"
assert_contains "a hook missing" "$TH_OUT" "hook SessionEnd not registered"
assert_not_contains "...the other one is there" "$TH_OUT" "hook SessionStart not registered"
assert_not_contains "a dead pid's leftover file is no problem" "$TH_OUT" "dead"
assert_eq "one line per problem" "4" "$(printf '%s\n' "$TH_OUT" | wc -l | tr -d ' ')"
rm -f "$DATA/sessions/u1/lifecycle.jsonl"
assert_contains "no start line" "$(at check)" "no start line in data/sessions/u1/lifecycle.jsonl"

# ---------------------------------------------------------------- last-seen-age, the quota jobs' input
section "last-seen-age: is a statusline on screen here?"
assert_match "claude: seconds since u1's tick" "$(at last-seen-age --agent claude)" '^[0-9]{1,3}$'
assert_eq "codex: none" "999999999" "$(at last-seen-age --agent codex)"
assert_eq "no data at all" "999999999" "$(AGENT_TRACKER_HOME="$S/none" python3 "$AT" last-seen-age)"
python3 -c "import sys; sys.path.insert(0, '$REPO_ROOT/src'); import codex_quota_api_poller" 2>/dev/null
assert_status "codex_quota_api_poller imports agent_tracker (no heartbeat file)" 0 $?
assert_contains "claude-quota.sh reads last-seen-age, not the heartbeat" "$(cat "$REPO_ROOT/jobs/claude-quota.sh")" "agent_tracker.py last-seen-age --agent claude"
assert_not_contains "...no heartbeat any more" "$(grep -v '^#' "$REPO_ROOT/jobs/claude-quota.sh")" "heartbeat"

section "the compatibility wrapper still prints its six fields"
out="$(python3 "$REPO_ROOT/src/statusline_payload_reader.py" < "$S/p1.json")"
assert_eq "six fields" "6" "$(awk -F $'\034' '{print NF}' <<< "$out")"

harness_summary
