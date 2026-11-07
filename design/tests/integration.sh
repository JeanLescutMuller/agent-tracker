#!/bin/bash
# integration.sh - agent-tracker v1 end to end, in a sandbox: install the five pieces into a fake HOME,
# run fake Claude sessions in a separate tmux server, check what each tool sees, simulate a crash and a
# reboot, restore with `ares tmux`, check the restore. Never touches the real HOME, launchd or tmux server.
#
# Usage: bash integration.sh [<sandbox dir>]
# Reads:  the worktrees in $W (branch agent-tracker-v1), /Users/jeanlescut/dev/agent-auto-close,
#         fixtures/statusline_payload.claude.json
# Writes: only under the sandbox dir; prints PASS/FAIL lines and a summary; logs in <sandbox>/log/
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
W="${W:-/private/tmp/claude-502/-Users-jeanlescut/cbf1952e-21d4-41ec-af21-d33f8a96cbba/scratchpad/wt}"
AAC="${AAC:-/Users/jeanlescut/dev/agent-auto-close}"
S="${1:-$(mktemp -d)}"
REAL_HOME=$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
mkdir -p "$S/home/.claude" "$S/log" "$S/out" "$S/bin" "$S/proj/alpha" "$S/proj/beta"

# --- sandbox environment: nothing points at the real home or the real tmux server ---
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID CLAUDECODE CODEX_HOME AGENT_USAGE_TRACKER_DIR
export HOME="$S/home" CLAUDE_CONFIG_DIR="$S/home/.claude" AGENT_TRACKER_HOME="$S/home/opt/agent-tracker"
# tmux sockets must stay under ~104 characters: a short folder under /tmp, holding only the sandbox socket
export AGENT_RESUME_HOME="$S/home/opt/agent-resume" TMUX_TMPDIR="$(mktemp -d /tmp/at-tmux.XXXXXX)" JR_MACHINE_NAME=test-machine
export FAKE_CLAUDE_FIXTURE="$HERE/../fixtures/statusline_payload.claude.json" FAKE_CLAUDE_OUT="$S/out"
SYS_DIRS="$(dirname "$(command -v tmux)"):$(dirname "$(command -v python3)"):$(dirname "$(command -v jq)"):/usr/bin:/bin:/usr/sbin:/sbin"
export PATH="$S/bin:$HOME/.local/bin:$SYS_DIRS"
export SHELL=/bin/zsh
: > "$HOME/.zshrc"                       # no zsh first-run wizard in new panes
[ "$HOME" != "$REAL_HOME" ] || { echo "refusing: HOME is the real home"; exit 2; }
case "$TMUX_TMPDIR" in /tmp/at-tmux.*) ;; *) echo "refusing: TMUX_TMPDIR not a sandbox folder"; exit 2 ;; esac

shopt -s nullglob
PASS=0; FAIL=0
check() { if eval "$2" >>"$S/log/checks.log" 2>&1; then PASS=$((PASS+1)); echo "PASS $1"; else FAIL=$((FAIL+1)); echo "FAIL $1"; fi; }
json() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$@"; }

# real-home fingerprint, to prove nothing changed
fp() { { md5 -q "$REAL_HOME/.claude/settings.json"; md5 -q "$REAL_HOME/.codex/config.toml" 2>/dev/null; \
        launchctl list | grep -ciE 'agent-tracker|agent-resume|auto-close'; \
        ls -d "$REAL_HOME"/opt/agent-tracker "$REAL_HOME"/opt/agent-resume "$REAL_HOME"/opt/agent-auto-close 2>/dev/null; \
        ls "$REAL_HOME/.local/bin" | grep -cE '^(agent-tracker|ares|agent-auto-close)$'; } 2>/dev/null; }
FP_BEFORE="$(fp)"

# fake `claude` on PATH: what `ares tmux` starts after the crash
cat > "$S/bin/claude" <<EOF
#!/bin/bash
exec python3 "$HERE/fake_claude.py" "\$@"
EOF
chmod +x "$S/bin/claude"

echo "== 1. install into the sandbox HOME"
(cd "$W/agent-statusline" && bash install.sh) >"$S/log/i-statusline.log" 2>&1;      check "agent-statusline install" "true"
(cd "$W/agent-usage-tracker" && bash install.sh) >"$S/log/i-tracker.log" 2>&1;      check "agent-tracker install (rc)" "[ -x '$HOME/.local/bin/agent-tracker' ]"
(cd "$W/my-setup" && INSTALL=true bash bootstrap.sh claude_config) >"$S/log/i-mysetup.log" 2>&1
check "my-setup writes the statusLine chain" "json '$CLAUDE_CONFIG_DIR/settings.json' \"d['statusLine']['command']\" | grep -qF '(agent-tracker tick 2>/dev/null || cat) | '"
SL_CMD=$(json "$CLAUDE_CONFIG_DIR/settings.json" "d['statusLine']['command']")
PATH="$S/bin:$SYS_DIRS" sh -c "$SL_CMD" < "$FAKE_CLAUDE_FIXTURE" > "$S/out/fallback.txt" 2> "$S/out/fallback.err"
check "statusline still draws when agent-tracker is missing" "grep -q 'Opus' '$S/out/fallback.txt'"
(cd "$W/agent-session-manager" && bash install.sh) >"$S/log/i-resume.log" 2>&1;    check "agent-resume install (ares on PATH)" "command -v ares"
(cd "$AAC" && bash install.sh) >"$S/log/i-autoclose.log" 2>&1;                     check "agent-auto-close install" "command -v agent-auto-close"
check "hooks: agent-tracker start/end registered" "grep -q 'agent-tracker hook start' '$CLAUDE_CONFIG_DIR/settings.json' && grep -q 'agent-tracker hook end' '$CLAUDE_CONFIG_DIR/settings.json'"
check "hooks: agent-resume SessionStart registered" "json '$CLAUDE_CONFIG_DIR/settings.json' \"json.dumps(d['hooks']['SessionStart'])\" | grep -q 'session_start'"

echo "== 2. fake Claude sessions in a sandbox tmux server (boot 1)"
BOOT1=1794000000; export AGENT_TRACKER_BOOT_TS=$BOOT1
U1=11111111-0000-4000-8000-000000000001; U2=22222222-0000-4000-8000-000000000002
U3=33333333-0000-4000-8000-000000000003; U4=44444444-0000-4000-8000-000000000004
tmux -f /dev/null new-session -d -s alpha -x 200 -y 50 -c "$S/proj/alpha"
tmux set-environment -g PATH "$PATH"
tmux split-window -h -t alpha:0 -c "$S/proj/alpha"
tmux split-window -v -t alpha:0.1 -c "$S/proj/alpha"
tmux new-window -t alpha:1 -c "$S/proj/beta"
tmux new-session -d -s beta -x 200 -y 50 -c "$S/proj/beta"
tmux split-window -h -t beta:0 -c "$S/proj/beta"
sleep 1
tmux send-keys -t alpha:0.0 "claude --uuid $U1" Enter
tmux send-keys -t alpha:1.0 "claude --uuid $U2" Enter
tmux send-keys -t beta:0.0 "claude --uuid $U3" Enter
tmux send-keys -t beta:0.1 "claude --uuid $U4" Enter
sleep 7
D="$AGENT_TRACKER_HOME/data/sessions"
for u in $U1 $U2 $U3 $U4; do
  check "start line for ${u:0:8}" "grep -q '\"event\": *\"start\"' '$D/$u/lifecycle.jsonl'"
  check "last_seen.json for ${u:0:8} has pane + layout" "json '$D/$u/last_seen.json' \"d['pane_id'] and d['window_layout'] and d['boot_ts']==$BOOT1\""
done
check "statusline shows the quota from quota_latest.json" "grep -q '42' '$S/out/$U1.statusline.txt' && [ -f '$AGENT_TRACKER_HOME/data/claude/quota_latest.json' ]"
check "SessionStart printed nothing but warnings (agent-tracker: empty)" "! grep 'agent-tracker hook start' '$S/out/$U1.hook-out.txt' | grep -v \"stdout=''\""

echo "== 3. a normal exit, a close, then what each tool sees"
PANE_U4=$(json "$D/$U4/last_seen.json" "d['pane_id']")
tmux send-keys -t "$PANE_U4" C-c; sleep 2
check "U4 exit wrote an end line" "grep -q '\"event\": *\"end\"' '$D/$U4/lifecycle.jsonl'"
agent-tracker now --json >"$S/out/now.json" 2>"$S/log/now.err"
check "now lists U1 U2 U3, not U4" "json '$S/out/now.json' \"sorted(r['uuid'][:8] for r in d)\" | grep -q \"'11111111', '22222222', '33333333'\" && ! grep -q $U4 '$S/out/now.json'"
check "now gives last_prompt from the transcript" "json '$S/out/now.json' \"all(r['last_prompt'] and r['last_prompt']['ts'] for r in d)\" | grep -q True"
agent-tracker check >"$S/out/check.txt" 2>&1; check "agent-tracker check is green" "grep -qi 'all good' '$S/out/check.txt'"
agent-auto-close idle --over 1 --dry-run >"$S/out/idle.txt" 2>&1
check "agent-auto-close idle --over 1h lists the 3 open ones" "grep -c '11111111\|22222222\|33333333' '$S/out/idle.txt' | grep -q 3"
PANE_U3=$(json "$D/$U3/last_seen.json" "d['pane_id']")
agent-auto-close close "$PANE_U3" >"$S/out/close.txt" 2>&1; sleep 2
check "agent-auto-close closed U3 (end line, screen file)" "grep -q '\"event\": *\"end\"' '$D/$U3/lifecycle.jsonl' && ls '$HOME/opt/agent-auto-close/data/close-screens/' | grep -q 33333333"
check "closed pane has 'claude --resume U3' pre-typed" "tmux capture-pane -p -t '$PANE_U3' | grep -q 'claude --resume $U3'"
ares resume --print-cmd --uuid "$U1" >"$S/out/resume_cmd.txt" 2>&1
check "ares resume --print-cmd gives claude --resume U1" "grep -q 'claude --resume $U1' '$S/out/resume_cmd.txt'"
geom() { sed -E 's/^[0-9a-f]{4},//; s/,[0-9]+([]},]|$)/\1/g'; }   # layout without its checksum and pane ids
LAYOUT_ALPHA0=$(tmux display -p -t alpha:0 '#{window_layout}' | geom)

echo "== 4. crash: every process dies, no end line; then a new boot"
for f in "$CLAUDE_CONFIG_DIR"/sessions/*.json; do kill -9 "$(json "$f" "d['pid']")" 2>/dev/null; rm -f "$f"; done
tmux kill-server; sleep 1
check "sandbox tmux server is gone" "! tmux ls 2>/dev/null"
export AGENT_TRACKER_BOOT_TS=$((BOOT1 + 7200))
ares tmux --dry-run --no-iterm >"$S/out/plan.txt" 2>&1
check "plan restores U1 and U2" "grep -q 11111111 '$S/out/plan.txt' && grep -q 22222222 '$S/out/plan.txt'"
check "plan skips U3 (closed) and U4 (exited)" "! grep -q '33333333\|44444444' '$S/out/plan.txt' || grep -iE '33333333|44444444' '$S/out/plan.txt' | grep -qiE 'skip|ended|not'"

echo "== 5. restore"
ares tmux --no-iterm >"$S/out/restore.txt" 2>&1; sleep 7
check "alpha is back; beta is not (its Claude sessions had ended)" "tmux has-session -t alpha && ! tmux has-session -t beta"
check "alpha:0 has its 3 panes" "[ \$(tmux list-panes -t alpha:0 | wc -l) -eq 3 ]"
check "alpha:0 pane geometry is the same as before the crash" "[ \"\$(tmux display -p -t alpha:0 '#{window_layout}' | geom)\" = '$LAYOUT_ALPHA0' ]"
check "U1 is running again (resume) in alpha:0.0" "tmux capture-pane -p -t alpha:0.0 | grep -q 'fake claude 11111111'"
check "U2 is running again in alpha:1" "tmux capture-pane -p -t alpha:1.0 | grep -q 'fake claude 22222222'"
check "U1 got a new start line (source resume, boot 2)" "tail -1 '$D/$U1/lifecycle.jsonl' | grep -q '\"source\": *\"resume\"'"
agent-tracker now --json >"$S/out/now2.json" 2>/dev/null
check "now (boot 2) shows U1 and U2" "grep -q $U1 '$S/out/now2.json' && grep -q $U2 '$S/out/now2.json'"
ares tmux --no-iterm >"$S/out/restore2.txt" 2>&1
check "a second ares tmux restores nothing more" "grep -q '0 Claude session' '$S/out/restore2.txt' && [ \$(tmux list-sessions | wc -l) -eq 1 ]"

echo "== 6. cleanup and the real home"
for f in "$CLAUDE_CONFIG_DIR"/sessions/*.json; do kill -TERM "$(json "$f" "d['pid']")" 2>/dev/null; done; sleep 1
tmux kill-server 2>/dev/null
check "real home, launchd and ~/.local/bin unchanged" "[ \"\$(fp)\" = \"\$FP_BEFORE\" ]"
echo "== $PASS passed, $FAIL failed   (sandbox: $S, logs: $S/log, outputs: $S/out)"
[ "$FAIL" -eq 0 ]
