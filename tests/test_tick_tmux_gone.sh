#!/bin/bash
# test_tick_tmux_gone.sh - regression test for 2026-11-07 15:30: the tmux server died, the Claude processes
# still ticked once, and `tick` overwrote the pane, window and layout in last_seen.json with nulls.
# Expected now: the last known tmux fields are kept for the same process.
# Sandbox only: own HOME and data, a tmux server on an explicit socket (-S); never the user's tmux server.
# Usage: bash tests/test_tick_tmux_gone.sh      Reads: src/agent_tracker.py, tests/fixtures/statusline_payload.claude.json
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
S=$(mktemp -d); SOCK=$(mktemp -d /tmp/att-XXXX)/s     # sockets must stay under ~104 characters
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID
export HOME="$S/home" CLAUDE_CONFIG_DIR="$S/home/.claude" AGENT_TRACKER_HOME="$S/home/opt/agent-tracker" JR_MACHINE_NAME=test-machine
mkdir -p "$CLAUDE_CONFIG_DIR/sessions" "$AGENT_TRACKER_HOME/data/sessions"
PASS=0; FAIL=0
ok() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS $1"; else FAIL=$((FAIL+1)); echo "FAIL $1"; fi; }
UUID=12345678-0000-4000-8000-0000000000aa
PAYLOAD=$(python3 -c "import json,sys; d=json.load(open('$HERE/tests/fixtures/statusline_payload.claude.json')); d.update(session_id='$UUID', cwd='$S'); print(json.dumps(d))")

tmux -S "$SOCK" -f /dev/null new-session -d -s alpha -x 120 -y 40 "sleep 60"
PANE=$(tmux -S "$SOCK" list-panes -t alpha -F '#{pane_id}')
# what tmux sets inside a pane: TMUX=<socket>,<server pid>,<session index>, TMUX_PANE=<pane id>
TMUX_VAL="$SOCK,$(tmux -S "$SOCK" display -p '#{pid}'),0"
tick() { TMUX="$TMUX_VAL" TMUX_PANE="$PANE" python3 "$HERE/src/agent_tracker.py" tick <<<"$PAYLOAD" >/dev/null; }
F="$AGENT_TRACKER_HOME/data/sessions/$UUID/last_seen.json"
field() { python3 -c "import json; print(json.load(open('$F')).get('$1'))"; }

tick
ok "with tmux: pane_id recorded" "[ \"\$(field pane_id)\" = '$PANE' ]"
ok "with tmux: layout recorded" "[ -n \"\$(field window_layout)\" ] && [ \"\$(field window_layout)\" != None ]"
LAYOUT=$(field window_layout)

tmux -S "$SOCK" kill-server; sleep 1
python3 - "$F" <<'EOF'
import json, sys; f = sys.argv[1]; d = json.load(open(f)); d["ts"] -= 120; json.dump(d, open(f, "w"))   # force a rewrite
EOF
tick
ok "tmux gone: pane_id kept" "[ \"\$(field pane_id)\" = '$PANE' ]"
ok "tmux gone: layout kept" "[ \"\$(field window_layout)\" = '$LAYOUT' ]"
ok "tmux gone: the file was rewritten (fresh ts)" "[ \$(( \$(date +%s) - \$(field ts) )) -lt 30 ]"

echo "== $PASS passed, $FAIL failed (sandbox $S)"
[ "$FAIL" -eq 0 ]
