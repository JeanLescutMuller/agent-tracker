#!/bin/bash
# test_codex_daemon.sh - regression test for 2026-11-07: since Codex 0.167 every Codex hook runs under ONE shared
# background process (`codex app-server`, parent pid 1), which keeps the $TMUX_PANE of the pane the first Codex window
# was opened in. The SessionStart hook recorded that process's pid and pane for every Codex session.
# Expected now: a hook run by that process writes no pid and no pane; the window's own status line (`tick --agent
# codex`, payload key thread_id) writes them in last_seen.json, and `now` takes them from there.
# Sandbox only: own HOME and data; every tmux call goes through tmux_guard.sh (explicit -S socket): this script re-runs
# itself under it. Usage: bash tests/test_codex_daemon.sh      Reads: src/agent_tracker.py. Writes: a mktemp sandbox.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "${TMUX_GUARD_SOCKET:-}" ] || exec bash "$HERE/tests/tmux_guard.sh" bash "$0" "$@"
S=$(mktemp -d)
unset CLAUDE_CODE_SESSION_ID
export HOME="$S/home" CLAUDE_CONFIG_DIR="$S/home/.claude" AGENT_TRACKER_HOME="$S/home/opt/agent-tracker" JR_MACHINE_NAME=test-machine
mkdir -p "$CLAUDE_CONFIG_DIR/sessions" "$AGENT_TRACKER_HOME/data/sessions" "$S/bin" "$S/run"
PASS=0; FAIL=0
ok() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS $1"; else FAIL=$((FAIL+1)); echo "FAIL $1"; fi; }
AT=(python3 "$HERE/src/agent_tracker.py")
U=01a1b71c-b4c2-7b31-aaf9-00000000c0de
F="$AGENT_TRACKER_HOME/data/sessions/$U"
# A process started as `codex <arg>`: bash under the name codex (argv[0] codex, argv[1] the script it runs). So
# `codex app-server` has the real background process's argv[0..1]; `codex window.sh` stands for a Codex window.
ln -s /bin/bash "$S/bin/codex"

tmux new-session -d -s work -x 160 -y 40 "sleep 120"; tmux split-window -d -t work:0 "sleep 120"
read -r PANE_A PANE_B <<<"$(tmux list-panes -t work:0 -F '#{pane_id}' | tr '\n' ' ')"

# -- the background process, started from pane A, runs the window's SessionStart hook ---------------------------
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$U" "$S" > "$S/run/start.json"
cat > "$S/run/app-server" <<EOF
${AT[*]} hook start --agent codex < "$S/run/start.json"
touch "$S/run/started"; exec sleep 120
EOF
(cd "$S/run" && TMUX_PANE=$PANE_A exec "$S/bin/codex" app-server) & DAEMON=$!
for _ in $(seq 50); do [ -e "$S/run/started" ] && break; sleep 0.1; done
start_field() { python3 -c "import json; print(json.loads(open('$F/lifecycle.jsonl').readlines()[-1]).get('$1'))"; }
ok "start line written for the Codex session" "[ \"\$(start_field event)\" = start ] && [ \"\$(start_field agent)\" = codex ]"
ok "start line: no pid (the background process is not the window)" "[ \"\$(start_field pid)\" = None ]"
ok "start line: no pane (pane A is not the window's)" "[ \"\$(start_field pane_id)\" = None ] && [ \"\$(start_field pane)\" = None ]"

# -- the window, in pane B: its status line ticks (payload: thread_id, as the patched Codex sends it) --------------
printf '{"thread_id":"%s","cwd":"%s","model":"gpt","rate_limits":{"five_hour":{"used_percentage":2}}}' "$U" "$S" > "$S/run/payload.json"
cat > "$S/run/window.sh" <<EOF
${AT[*]} tick --agent codex < "$S/run/payload.json" > /dev/null
touch "$S/run/ticked"; exec sleep 120
EOF
(cd "$S/run" && TMUX_PANE=$PANE_B exec "$S/bin/codex" window.sh) & WINDOW=$!
for _ in $(seq 50); do [ -e "$S/run/ticked" ] && break; sleep 0.1; done
seen_field() { python3 -c "import json; print(json.load(open('$F/last_seen.json')).get('$1'))"; }
ok "tick: last_seen.json written from thread_id" "[ -f '$F/last_seen.json' ]"
ok "tick: the window's pane (B)" "[ \"\$(seen_field pane_id)\" = '$PANE_B' ]"
ok "tick: the window's pid" "[ \"\$(seen_field pid)\" = '$WINDOW' ]"

now_field() { "${AT[@]}" now --json | python3 -c "import json,sys; r=[x for x in json.load(sys.stdin) if x['uuid']=='$U']; print(r[0].get('$1') if r else 'absent')"; }
ok "now: the session is listed, with the window's pid" "[ \"\$(now_field pid)\" = '$WINDOW' ]"
ok "now: with the window's pane (B), not A" "[ \"\$(now_field pane_id)\" = '$PANE_B' ]"
kill "$WINDOW" 2>/dev/null; wait "$WINDOW" 2>/dev/null
ok "now: the window closed (no end line), the background process alive: not listed" "[ \"\$(now_field pid)\" = absent ]"

# -- the end hook, run by the background process: no pid either -------------------------------------------------
printf '{"session_id":"%s","reason":"prompt_input_exit"}' "$U" > "$S/run/end.json"
cat > "$S/run/app-server" <<EOF
${AT[*]} hook end --agent codex < "$S/run/end.json"
EOF
(cd "$S/run" && TMUX_PANE=$PANE_A "$S/bin/codex" app-server)
ok "end line: no pid" "[ \"\$(start_field event)\" = end ] && [ \"\$(start_field pid)\" = None ]"
kill "$DAEMON" 2>/dev/null; wait "$DAEMON" 2>/dev/null

# -- an older Codex, whose hooks the window runs itself: pid and pane kept as before --------------------------------
U2=01a1b71c-b4c2-7b31-aaf9-00000000c0d2
printf '{"session_id":"%s","cwd":"%s","source":"startup"}' "$U2" "$S" > "$S/run/start2.json"
cat > "$S/run/old-window.sh" <<EOF
${AT[*]} hook start --agent codex < "$S/run/start2.json"
EOF
(cd "$S/run" && TMUX_PANE=$PANE_B exec "$S/bin/codex" old-window.sh) & OLD=$!; wait "$OLD"
F="$AGENT_TRACKER_HOME/data/sessions/$U2"
ok "hook run by the window itself: its pid kept" "[ \"\$(start_field pid)\" = '$OLD' ]"
ok "hook run by the window itself: its pane kept" "[ \"\$(start_field pane_id)\" = '$PANE_B' ]"

echo "== $PASS passed, $FAIL failed (sandbox $S)"
[ "$FAIL" -eq 0 ]
