#!/bin/bash
# Tests for the terminal snapshot: src/terminal_snapshot.sh (data/snapshots/<boot_ts>.tsv) and its start by
# `agent-tracker tick` (at most once a minute, in the background). Sandbox: own HOME and runtime, a tmux server
# of its own (TMUX_TMPDIR; run the suite under tests/tmux_guard.sh for an explicit -S socket), a fake osascript
# (harness.sh: prints $TH_FAKE_ITERM) instead of the user's iTerm2.
# Usage: bash tests/test_terminal_snapshot.sh      Reads: src/terminal_snapshot.sh, src/agent_tracker.py
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

S="$(mktemp -d "${TMPDIR:-/tmp}/at-snap.XXXXXX")"
TMUX_DIR="$(mktemp -d /tmp/ats.XXXXXX)"   # tmux's socket path must stay under ~104 bytes
export HOME="$S/home" AGENT_TRACKER_HOME="$S/rt" TMUX_TMPDIR="$TMUX_DIR" JR_MACHINE_NAME=test-machine \
    CLAUDE_CONFIG_DIR="$S/home/.claude" AGENT_TRACKER_BOOT_TS=1794925607
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR/sessions"
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$S" "$TMUX_DIR"; }
trap cleanup EXIT
SNAP="$REPO_ROOT/src/terminal_snapshot.sh"
OUT="$S/rt/data/snapshots/1794925607.tsv"
snap() { bash "$SNAP" "$S/rt" 1794925607; }
kind() { awk -F '\t' -v k="$1" '$3 == k' "$OUT"; }
# Under tests/run.sh + tmux_guard.sh every test file shares one tmux server: count only this file's tmux sessions
mine() { kind pane | awk -F '\t' '$4 == "jobs/interviewing" || $4 == "snap-general"' | wc -l | tr -d ' '; }

tmux new-session -d -s "jobs/interviewing" -x 200 -y 50 -n "w one" -c "$S" "sleep 600"
tmux split-window -t "jobs/interviewing:0" -h -c "$HOME" "sleep 600"
tmux new-session -d -s snap-general -x 120 -y 40 "sleep 600"
printf '1\t225\t1\t/dev/ttys039\t2,39,1660,1156\n2\t263\t1\t/dev/ttys035\t-338,-1651,1800,-21\n' > "$S/iterm1"

section "one snapshot: tmux panes and iTerm2 tabs, ts and dt first"
TH_FAKE_ITERM="$S/iterm1" snap
assert_file_exists "the boot's file" "$OUT"
assert_eq "3 panes" "3" "$(mine)"
assert_eq "pane: session, window, pane index, command, folder, window name" "jobs/interviewing|0|1|sleep|$(cd "$HOME" && pwd -P)|w one" \
    "$(kind pane | awk -F '\t' '$4 == "jobs/interviewing" && $5 == 0 && $6 == 1 {print $4 "|" $5 "|" $6 "|" $8 "|" $9 "|" $11}')"
assert_match "ts and dt first" "$(head -1 "$OUT")" $'^[0-9]{10}\t[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\tpane\t'
assert_eq "iTerm2 rows: window, id, tab, tty, bounds" "2|263|1|/dev/ttys035|-338,-1651,1800,-21" \
    "$(kind iterm | awk -F '\t' '$4 == 2 {print $4 "|" $5 "|" $6 "|" $7 "|" $8}')"
assert_eq "no client attached: no client row" "0" "$(kind client | wc -l | tr -d ' ')"

section "unchanged: the file is left alone; iTerm2 is not asked again before 600 s"
before="$(cat "$OUT")"; touch -t 202001010000 "$OUT"
printf '1\t999\t1\t/dev/ttys099\t0,0,1,1\n' > "$S/iterm2"
TH_FAKE_ITERM="$S/iterm2" snap
assert_eq "not rewritten" "$before" "$(cat "$OUT")"
assert_match "mtime kept" "$(stat -f %Sm -t %Y "$OUT" 2>/dev/null || date -r "$OUT" +%Y)" '^2020$'

section "a change in tmux: rewritten, the old iTerm2 rows kept"
tmux kill-session -t snap-general
TH_FAKE_ITERM="$S/iterm2" snap
assert_eq "2 panes now" "2" "$(mine)"
assert_contains "iTerm2 rows unchanged (not asked: no client changed)" "$(kind iterm)" "/dev/ttys039"

section "iTerm2 rows older than 600 s: asked again"
AGENT_TRACKER_ITERM_EVERY_S=0 TH_FAKE_ITERM="$S/iterm2" snap
assert_eq "the new iTerm2 rows" "/dev/ttys099" "$(kind iterm | cut -f7)"

section "iTerm2 not answering: the previous rows are kept"
AGENT_TRACKER_ITERM_EVERY_S=0 snap
assert_eq "kept" "/dev/ttys099" "$(kind iterm | cut -f7)"

section "no tmux server: nothing written"
before="$(cat "$OUT")"; tmux kill-server; sleep 0.2
snap; rc=$?
assert_eq "exit 0, file unchanged" "0|$before" "$rc|$(cat "$OUT")"

section "tick starts it at most once a minute, in the background"
tmux new-session -d -s snap-work -x 100 -y 30 "sleep 600"
jq -c '.session_id = "u1" | .cwd = "/work"' "$TESTS_DIR/fixtures/statusline_payload.claude.json" > "$S/p.json"
rm -f "$OUT"
python3 "$REPO_ROOT/src/agent_tracker.py" tick < "$S/p.json" > /dev/null
for i in $(seq 1 50); do [ -s "$OUT" ] && break; sleep 0.1; done
assert_contains "snapshot written after a tick" "$(kind pane)" "snap-work"
assert_file_exists "the start stamp" "$S/rt/data/snapshots/.last_run"
rm -f "$OUT"
python3 "$REPO_ROOT/src/agent_tracker.py" tick < "$S/p.json" > /dev/null; sleep 0.5
assert_file_missing "a second tick within 60 s starts none" "$OUT"
touch -t 202001010000 "$S/rt/data/snapshots/.last_run"
python3 "$REPO_ROOT/src/agent_tracker.py" tick < "$S/p.json" > /dev/null
for i in $(seq 1 50); do [ -s "$OUT" ] && break; sleep 0.1; done
assert_file_exists "a stamp older than 60 s: started again" "$OUT"

section "tmux only in ~/.local/bin, not on PATH (the NAS's, from a service): still found"
mkdir -p "$HOME/.local/bin"; ln -sf "$(command -v tmux)" "$HOME/.local/bin/tmux"
tmux new-session -d -s snap-path -x 100 -y 30 "sleep 600"
rm -f "$OUT"
PATH=/usr/bin:/bin bash "$SNAP" "$S/rt" 1794925607
assert_contains "snapshot written" "$(kind pane)" "snap-path"

harness_summary
