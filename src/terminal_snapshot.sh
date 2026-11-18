#!/bin/bash
# ~/opt/agent-tracker/src/terminal_snapshot.sh RUNTIME BOOT_TS: one snapshot of the terminal layout (tmux + iTerm2),
# for `ares tmux` (agent-resume) to put it back after a crash. Started in the background by `agent-tracker tick`
# at most once a minute (data/snapshots/.last_run), so only while a Claude session runs. FOR_READERS.md §4.
#
# Writes RUNTIME/data/snapshots/<BOOT_TS>.tsv (temp + rename), only when its content changed; one file per boot, so
# the first snapshot after a reboot never overwrites the previous boot's. Rows, tab-separated, ts and dt first:
#   ts dt pane   <tmux session> <window index> <pane index> <pane_id> <command> <pane folder> <window layout> <window name>
#   ts dt client <tty> <tmux session>
#   ts dt iterm  <window position, 1 = front> <window id> <tab position> <tty> <window bounds x1,y1,x2,y2>
# <command>: the pane's foreground command (a shell, or Claude Code's version, "2.1.326"): was Claude still running there.
# ts/dt of a row: when that part was read (the iTerm2 rows can be older than the tmux ones).
#
# Cost (2026-11-17, 9 iTerm2 tabs): the tmux part ≈ 8 ms of CPU; the iTerm2 part ≈ 70 ms (osascript + iTerm2's own),
# so it runs only when the tmux clients changed (a tab opened or closed) or its rows are >= 600 s old (a dragged tab).
# Never fails loudly: any error leaves the previous file as it was.
RUNTIME=$1 BOOT_TS=$2
# tmux installed without root lives in ~/.local/bin (the NAS, 2026-11-18); a tick from a service has systemd's
# PATH, without it.
PATH="$PATH:$HOME/.local/bin"
ITERM_EVERY_S=${AGENT_TRACKER_ITERM_EVERY_S:-600}
[[ $BOOT_TS =~ ^[0-9]+$ ]] || exit 0
dir=$RUNTIME/data/snapshots out=$RUNTIME/data/snapshots/$BOOT_TS.tsv
mkdir -p "$dir" || exit 0
now=$(date +%s)
T=$'\t'
stamp="$now$T$(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)"

panes=$(tmux list-panes -a -F "pane$T#{session_name}$T#{window_index}$T#{pane_index}$T#{pane_id}$T#{pane_current_command}$T#{pane_current_path}$T#{window_layout}$T#{window_name}" 2>/dev/null) || exit 0
clients=$(tmux list-clients -F "client$T#{client_tty}$T#{session_name}" 2>/dev/null)

body() { cut -f3- "$out" 2>/dev/null | grep "^$1$T"; }   # the previous file's rows of one kind, without ts and dt
old_iterm=$(grep "^[0-9]*$T[^$T]*${T}iterm$T" "$out" 2>/dev/null)
old_iterm_ts=$(echo "$old_iterm" | head -1 | cut -f1)
iterm=$old_iterm
if command -v osascript >/dev/null && { [ "$clients" != "$(body client)" ] || [ -z "$old_iterm" ] ||
                                        [ $((now - ${old_iterm_ts:-0})) -ge "$ITERM_EVERY_S" ]; }; then
    # One line per iTerm2 session (3 Apple events in all, then local loops): position, id, tab, tty, bounds
    rows=$(osascript - 2>/dev/null <<'EOF'
tell application "iTerm2"
	set l_ids to id of windows
	set l_bounds to bounds of windows
	set l_ttys to tty of sessions of tabs of windows
end tell
set out to ""
repeat with w from 1 to count of l_ids
	set b to item w of l_bounds
	set bs to ((item 1 of b) as text) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b)
	set l_tabs to item w of l_ttys
	repeat with t from 1 to count of l_tabs
		repeat with s in item t of l_tabs
			set out to out & w & tab & (item w of l_ids) & tab & t & tab & s & tab & bs & linefeed
		end repeat
	end repeat
end repeat
return out
EOF
    ) && iterm=$(echo "$rows" | grep . | sed "s/^/$stamp${T}iterm$T/")
fi

# Unchanged (ts and dt aside): leave the file alone
[ "$panes" = "$(body pane)" ] && [ "$clients" = "$(body client)" ] && [ "$iterm" = "$old_iterm" ] && exit 0
tmp=$out.tmp.$$
{ echo "$panes" | sed "s/^/$stamp$T/"
  if [ -n "$clients" ]; then echo "$clients" | sed "s/^/$stamp$T/"; fi
  if [ -n "$iterm" ]; then echo "$iterm"; fi
} > "$tmp" && mv -f "$tmp" "$out" || rm -f "$tmp"
