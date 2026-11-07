#!/bin/bash
# tmux_guard.sh - run a test command so that EVERY tmux call it makes (the test's own and the tested code's)
# goes to a throwaway tmux server on an explicit socket (-S), never to the user's tmux server.
#
# Why: on 2026-11-07 15:30 a test's `TMUX_TMPDIR=$d tmux kill-server` killed the user's real tmux server:
# with $TMUX set, tmux ignores TMUX_TMPDIR. The user's rule since: every tmux command in a test uses -S.
#
# Usage: bash tests/tmux_guard.sh <command> [args...]      e.g. bash tests/tmux_guard.sh bash tests/test_agent_tracker.sh
# How:   a `tmux` wrapper first on PATH that runs the real tmux as `tmux -S $TMUX_GUARD_SOCKET "$@"`, refuses to run
#        without that socket, and unsets TMUX/TMUX_PANE for the command. The socket's server is killed at the end.
# Writes: one small folder /tmp/tmux-guard.* (short path: sockets are limited to ~104 characters); left for
#         the OS to clear (no rm of a variable path).
set -uo pipefail
[ $# -ge 1 ] || { echo "usage: tmux_guard.sh <command> [args...]" >&2; exit 2; }
REAL_TMUX=$(PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/tmux-guard\.' | paste -sd: -) command -v tmux) \
    || { echo "tmux_guard: no tmux found" >&2; exit 2; }
G=$(mktemp -d /tmp/tmux-guard.XXXXXX)
mkdir -p "$G/bin"
export TMUX_GUARD_SOCKET="$G/sock" TMUX_GUARD_REAL="$REAL_TMUX"
cat > "$G/bin/tmux" <<'EOF'
#!/bin/bash
# tmux wrapper of tmux_guard.sh: every call goes to the test socket, whatever the caller says.
[ -n "${TMUX_GUARD_SOCKET:-}" ] || { echo "tmux_guard: refusing a tmux call without TMUX_GUARD_SOCKET" >&2; exit 97; }
for a in "$@"; do case "$a" in -L*|-S*) echo "tmux_guard: refusing a caller-chosen socket ($a)" >&2; exit 97 ;; esac; done
unset TMUX TMUX_PANE
exec "$TMUX_GUARD_REAL" -S "$TMUX_GUARD_SOCKET" "$@"
EOF
chmod +x "$G/bin/tmux"
unset TMUX TMUX_PANE
export PATH="$G/bin:$PATH" TMUX_TMPDIR="$G"
"$@"; rc=$?
"$REAL_TMUX" -S "$TMUX_GUARD_SOCKET" kill-server 2>/dev/null
exit $rc
