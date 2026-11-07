#!/bin/bash
# Removes everything install.sh deploys: the jobs' entrypoints and triggers
# and the telemetry receiver (LaunchAgents or systemd --user units), the telemetry
# keys in ~/.claude/settings.json's `env` (only those still holding our
# values), our SessionStart / SessionEnd hook groups there, the Codex plugin,
# the ~/.local/bin/agent-tracker link, and the code/state/logs under
# ~/opt/agent-tracker, and data/<agent>/intermediary.db (local working
# tables, rebuilt from the transcripts).
#
# Deliberately preserves the rest of data/ - irreplaceable usage history,
# not reproducible if deleted (on the VM it holds the Mac's slots too), and
# data/sessions/ (where each Claude session ran, its lifecycle).
# Remove it yourself if you really want it gone.
#
# With this uninstalled, agent-statusline keeps working: it finds no
# data/claude/quota_latest.json and shows the rate_limits on its own stdin;
# my-setup's statusLine then calls the display alone (DESIGN.md §6).
#
# Anything left under ~/opt/agent-tracker after that is an orphan -
# not something this script recognizes - and gets listed for you to check
# by hand rather than being silently deleted or ignored.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

RUNTIME="$HOME/opt/agent-tracker"
BIN_DIR="$HOME/.local/bin"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
JOBS="claude-quota codex-quota codex-plan-history aggregates"   # as in install.sh
LABELS="com.jeanlescut.agent-tracker.otel"
for job in $JOBS; do LABELS="$LABELS com.jeanlescut.agent-tracker.$job"; done
SYSTEMD_USER="$HOME/.config/systemd/user"
OS="${AGENT_TRACKER_OS:-$(uname -s)}"
CODEX_BIN="${AGENT_TRACKER_CODEX_BIN:-$(command -v codex 2>/dev/null || true)}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} agent-tracker uninstall${NC}"
echo -e "${GREEN}========================================${NC}"

step "scheduled jobs"
for label in $LABELS; do
    if [ "$OS" = Darwin ]; then
        if [ -L "$LAUNCH_AGENTS/$label.plist" ] || [ -f "$LAUNCH_AGENTS/$label.plist" ] || [ -f "$RUNTIME/$label.plist" ]; then
            [ -n "${AGENT_TRACKER_SKIP_LAUNCHD:-}" ] || \
                launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENTS/$label.plist" 2>/dev/null || true
            rm -f "$LAUNCH_AGENTS/$label.plist" "$RUNTIME/$label.plist"
            installed "unloaded and removed $label"
        else
            ok "$label already absent"
        fi
    else
        if [ -e "$SYSTEMD_USER/$label.service" ] || [ -L "$SYSTEMD_USER/$label.service" ] || [ -f "$RUNTIME/$label.service" ]; then
            [ -n "${AGENT_TRACKER_SKIP_LAUNCHD:-}" ] || \
                systemctl --user disable --now "$label.timer" "$label.service" >/dev/null 2>&1 || true
            rm -f "$SYSTEMD_USER/$label.service" "$SYSTEMD_USER/$label.timer" "$RUNTIME/$label.service" "$RUNTIME/$label.timer"
            installed "stopped and removed $label"
        else
            ok "$label already absent"
        fi
    fi
done
[ "$OS" = Darwin ] || [ -n "${AGENT_TRACKER_SKIP_LAUNCHD:-}" ] || systemctl --user daemon-reload 2>/dev/null || true

step "claude telemetry settings"
case "$(python3 "$SCRIPT_DIR/src/merge_claude_env.py" unset)" in
    changed) installed "removed the telemetry env vars from ~/.claude/settings.json" ;;
    *) ok "telemetry env vars already absent" ;;
esac

step "lifecycle hooks"
case "$(python3 "$SCRIPT_DIR/src/merge_claude_hooks.py" unset)" in
    changed) installed "removed agent-tracker's SessionStart / SessionEnd hooks from ~/.claude/settings.json" ;;
    *) ok "agent-tracker's Claude hooks already absent" ;;
esac
if [ -n "$CODEX_BIN" ] && [ -x "$CODEX_BIN" ]; then
    "$CODEX_BIN" plugin remove agent-tracker@agent-tracker-local >/dev/null 2>&1 || true
    "$CODEX_BIN" plugin marketplace remove agent-tracker-local >/dev/null 2>&1 || true
    installed "removed the agent-tracker Codex plugin and marketplace (if present)"
fi
if [ "$(readlink "$BIN_DIR/agent-tracker" 2>/dev/null)" = "$RUNTIME/src/agent_tracker.py" ]; then
    rm -f "$BIN_DIR/agent-tracker"
    installed "removed $BIN_DIR/agent-tracker"
else
    ok "$BIN_DIR/agent-tracker already absent (or not ours)"
fi

step "runtime tree ($RUNTIME)"
if [ -d "$RUNTIME" ]; then
    # Nothing here is written on every render except the databases under
    # data/ (kept), so a plain rm -rf is enough - no retry loop needed.
    known_targets="src state logs codex-plugin codex-marketplace"
    for target in $known_targets; do
        rm -rf "${RUNTIME:?}/$target"
    done
    for job in $JOBS; do
        rm -f "${RUNTIME:?}/$job.sh" "${RUNTIME:?}/$job.conf"
    done
    for agent in claude codex; do
        rm -f "$RUNTIME/data/$agent/intermediary.db" "$RUNTIME/data/$agent/intermediary.db-wal" "$RUNTIME/data/$agent/intermediary.db-shm"
    done
    installed "removed deployed code, state, logs and the intermediary tables"
    # rmdir only succeeds on an empty directory - real history is kept.
    rmdir "$RUNTIME/data/claude/aggregates" "$RUNTIME/data/codex/aggregates" 2>/dev/null
    rmdir "$RUNTIME/data/claude" "$RUNTIME/data/codex" "$RUNTIME/data/sessions" 2>/dev/null
    rmdir "$RUNTIME/data" 2>/dev/null
    [ -d "$RUNTIME/data" ] && skip "preserved $RUNTIME/data (irreplaceable usage history)"

    # A known target back already means a live Claude render ran the ingest
    # script mid-uninstall (it mkdirs state/quota/) - not an orphan.
    orphans="$(find "$RUNTIME" -mindepth 1 -maxdepth 1 ! -name data \
        ! -name bin ! -name src ! -name state ! -name logs 2>/dev/null)"
    if [ -n "$orphans" ]; then
        fail "orphan files/dirs under $RUNTIME - not recognized by this script, check by hand:"
        printf '%s\n' "$orphans" | sed 's/^/      /'
    else
        rmdir "$RUNTIME" 2>/dev/null || true
        ok "no orphans found"
    fi
else
    ok "$RUNTIME already absent"
fi

echo ""
