#!/bin/bash
# Idempotent installer for agent-tracker (agent-usage-tracker until 2026-11),
# for a machine with no prior install. Carries no one-time migration logic on
# purpose (AGENTS.md "Install, deploy"): it refuses to start while the old
# runtime ~/opt/agent-usage-tracker still holds data/ and the new one has
# none - moving it is a deploy step, doc/deploy_migration.md.
#
# Deploys, under ~/opt/agent-tracker:
# - src/*.py: the three gates (ingest_*.py, the only writers of the
#   databases), the collectors, usage_db.py, and agent_tracker.py, the
#   `agent-tracker` command (tick, hook start|end, now, check), linked from
#   ~/.local/bin/agent-tracker; its first line is this machine's python with
#   -S and its MACHINE_NAME is filled in, as for statusline_payload_reader.py
#   (the compatibility wrapper the old statusline still runs);
# - the jobs' job-runner entrypoints (<job>.sh, from jobs/), their dashboard
#   settings (<job>.conf, given to job-runner's dashboard by put-conf.sh) and one trigger
#   each, com.jeanlescut.agent-tracker.<job>: claude-quota (60s tick),
#   aggregates (every 5 min), and on macOS only codex-quota (60s)
#   and codex-plan-history (hourly); each entrypoint decides, works and
#   records its checks through job-runner (separate project,
#   ~/opt/job-runner/lib.sh);
# - the telemetry receiver, a service (always running, no job-runner);
#   LaunchAgents on macOS, systemd --user units on Linux (the VM) - plus the
#   telemetry keys in ~/.claude/settings.json's `env`;
# - the two lifecycle hooks: Claude Code's SessionStart / SessionEnd groups
#   in ~/.claude/settings.json (`agent-tracker hook start|end`), and, where
#   Codex is, the same as a Codex plugin (src/codex-plugin/, through a local
#   marketplace, registered by `codex plugin`, as agent-session-manager's
#   install does).
# The databases (data/<agent>/account_quotas.db, sessions_usages.db) are
# created by the gates on first write, data/sessions/ by the first tick or hook.
# The statusLine chain (`agent-tracker tick | display`) is my-setup's, not ours.
# Does NOT deploy adhoc_quotas_analysis/: run-by-hand research tooling stays
# in ~/dev/agent-tracker and runs from there (~/opt is for what a
# scheduler runs unattended).
#
# Independent of agent-statusline: either can be installed first, or alone.
# Without the statusline chain there are no push rows and the Claude poller
# stays on its idle cadence (doc/design.md §7.1).
# Without job-runner the triggers run, but every check fails until it is
# installed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

command -v python3 >/dev/null 2>&1 || { echo "python3 not found on PATH"; exit 1; }
PYTHON3="$(command -v python3)"
# This machine's name, by usage_db.machine_name() (skill machine-name): written into the
# statusline's entry point, so a render needs no scutil call.
MACHINE="$("$PYTHON3" -c "import sys; sys.path.insert(0, '$SCRIPT_DIR/src'); import usage_db; print(usage_db.machine_name())")" \
    || { echo "no machine name: macOS sudo scutil --set HostName <name>; Linux sudo hostnamectl set-hostname <name>" >&2; exit 1; }

RUNTIME="$HOME/opt/agent-tracker"
OLD_RUNTIME="$HOME/opt/agent-usage-tracker"   # before the rename (doc/deploy_migration.md)
BIN_DIR="$HOME/.local/bin"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
SYSTEMD_USER="$HOME/.config/systemd/user"
# Darwin -> LaunchAgents, anything else -> systemd --user. Overridable so the
# tests can render the Linux units on a Mac.
OS="${AGENT_TRACKER_OS:-$(uname -s)}"
# Codex, for its hooks: tests point this at a fake.
CODEX_BIN="${AGENT_TRACKER_CODEX_BIN:-$(command -v codex 2>/dev/null || true)}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} agent-tracker install${NC}"
echo -e "${GREEN}========================================${NC}"

_deploy() {
    local src="$1" target="$2"
    mkdir -p "$(dirname "$target")"
    if [ -f "$target" ] && diff -q "$src" "$target" >/dev/null 2>&1; then
        ok "$(basename "$target")"
        return
    fi
    cp "$src" "$target"
    chmod +x "$target" 2>/dev/null || true
    installed "$(basename "$target")"
}

# A template with its placeholders filled: this machine's interpreter, the
# runtime tree, and for a job's trigger $JOB and $INTERVAL (seconds).
_render() {
    sed -e "s#__PYTHON3__#$PYTHON3#g" -e "s#__RUNTIME__#$RUNTIME#g" -e "s#__MACHINE_NAME__#$MACHINE#g" \
        -e "s#__JOB__#${JOB:-}#g" -e "s#__INTERVAL__#${INTERVAL:-}#g" "$1"
}

# Like _deploy, with __PYTHON3__ replaced by this machine's interpreter.
_deploy_rendered() {
    local src="$1" target="$2" tmp
    tmp="$(mktemp)"
    _render "$src" > "$tmp"
    _deploy "$tmp" "$target"
    rm -f "$tmp"
}

# Renders a LaunchAgent template into the runtime tree (the real file) and
# symlinks it from ~/Library/LaunchAgents, then (re)loads it - always
# restarting, so redeployed code takes effect.
_launch_agent() {
    local template="$1" label="$2" what="$3"
    local real="$RUNTIME/$label.plist" link="$LAUNCH_AGENTS/$label.plist" tmp
    mkdir -p "$LAUNCH_AGENTS"
    tmp="$(mktemp)"
    _render "$template" > "$tmp"
    if [ -f "$real" ] && diff -q "$tmp" "$real" >/dev/null 2>&1; then
        rm -f "$tmp"
        ok "$label"
    else
        mv "$tmp" "$real"
        installed "$label ($what)"
    fi
    ln -sf "$real" "$link"
    if [ -z "${AGENT_TRACKER_SKIP_LAUNCHD:-}" ]; then
        launchctl bootout "gui/$(id -u)" "$link" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$link"
    fi
}

# Renders a systemd --user unit (and its timer, if the job has one) from
# src/systemd/<template>.{service,timer} into the runtime tree (the real
# files), symlinks them from ~/.config/systemd/user, then enables and
# (re)starts them - always restarting, so redeployed code takes effect.
# Linger lets them run without a login session (best effort).
_systemd_unit() {
    local template="$1" label="$2" what="$3" kind real link tmp changed=false
    mkdir -p "$SYSTEMD_USER"
    for kind in service timer; do
        [ -f "$SCRIPT_DIR/src/systemd/$template.$kind" ] || continue
        real="$RUNTIME/$label.$kind" link="$SYSTEMD_USER/$label.$kind"
        tmp="$(mktemp)"
        _render "$SCRIPT_DIR/src/systemd/$template.$kind" > "$tmp"
        if [ -f "$real" ] && diff -q "$tmp" "$real" >/dev/null 2>&1; then
            rm -f "$tmp"
        else
            mv "$tmp" "$real"
            changed=true
        fi
        ln -sf "$real" "$link"
    done
    if [ "$changed" = true ]; then installed "$label ($what)"; else ok "$label"; fi
    if [ -z "${AGENT_TRACKER_SKIP_LAUNCHD:-}" ]; then
        systemctl --user daemon-reload
        if [ -f "$RUNTIME/$label.timer" ]; then
            systemctl --user enable --now "$label.timer" >/dev/null 2>&1
        else
            systemctl --user enable "$label.service" >/dev/null 2>&1
            systemctl --user restart "$label.service"
        fi
    fi
}

# _schedule TEMPLATE LABEL WHAT: src/launchd/TEMPLATE.plist.template or
# src/systemd/TEMPLATE.{service,timer}, as the trigger LABEL.
_schedule() {
    if [ "$OS" = Darwin ]; then
        _launch_agent "$SCRIPT_DIR/src/launchd/$1.plist.template" "$2" "$3"
    else
        _systemd_unit "$1" "$2" "$3"
    fi
}

# Each job: name, its trigger's interval in seconds (as in the header of its
# entrypoint, jobs/<job>.sh). The Codex jobs only where Codex is (the Mac).
JOBS="claude-quota:60 aggregates:300"
[ "$OS" = Darwin ] && JOBS="$JOBS codex-quota:60 codex-plan-history:3600"

if [ -d "$OLD_RUNTIME/data" ] && [ ! -d "$RUNTIME/data" ]; then
    fail "$OLD_RUNTIME/data exists and $RUNTIME/data does not: move it first (doc/deploy_migration.md), then re-run"
    exit 1
fi

step "runtime layout"
# data/<agent>/account_quotas.db + sessions_usages.db - see
# doc/design.md §2.
mkdir -p "$RUNTIME/data/claude" "$RUNTIME/data/codex" "$RUNTIME/data/sessions" "$RUNTIME/state" "$RUNTIME/logs"
ok "data/, state/, logs/"

step "code"
for f in "$SCRIPT_DIR"/src/*.py; do
    # The settings merge helpers run from the repo (below), never deployed.
    case "$(basename "$f")" in merge_claude_env.py|merge_claude_hooks.py) continue;; esac
    if [ "$(basename "$f")" = statusline_payload_reader.py ] || [ "$(basename "$f")" = agent_tracker.py ]; then
        # Run directly on every statusline render (agent_tracker.py as `agent-tracker tick`): its first
        # line is this machine's interpreter (-S: no site-packages, faster), and its MACHINE_NAME is filled in.
        tmp="$(mktemp)"
        sed -e "1s|.*|#!$PYTHON3 -S|" "$f" > "$tmp"
        _deploy_rendered "$tmp" "$RUNTIME/src/$(basename "$f")"
        rm -f "$tmp"
        continue
    fi
    _deploy "$f" "$RUNTIME/src/$(basename "$f")"
done
mkdir -p "$BIN_DIR"
if [ "$(readlink "$BIN_DIR/agent-tracker" 2>/dev/null)" = "$RUNTIME/src/agent_tracker.py" ]; then
    ok "$BIN_DIR/agent-tracker"
else
    ln -sfn "$RUNTIME/src/agent_tracker.py" "$BIN_DIR/agent-tracker"
    installed "$BIN_DIR/agent-tracker -> $RUNTIME/src/agent_tracker.py"
fi

step "jobs and their triggers ($([ "$OS" = Darwin ] && echo LaunchAgents || echo 'systemd --user'))"
for entry in $JOBS; do
    JOB="${entry%%:*}" INTERVAL="${entry#*:}"
    _deploy "$SCRIPT_DIR/jobs/$JOB.sh" "$RUNTIME/$JOB.sh"
    # Its dashboard settings, beside it; job-runner's put-conf.sh gives them to the dashboard on the VM (job-runner DESIGN §11)
    _deploy "$SCRIPT_DIR/jobs/$JOB.conf" "$RUNTIME/$JOB.conf"
    if [ -f "$HOME/opt/job-runner/put-conf.sh" ]; then
        bash "$HOME/opt/job-runner/put-conf.sh" "agent-tracker.$JOB" "$RUNTIME/$JOB.conf" >/dev/null && ok "dashboard settings of $JOB" || skip "dashboard settings of $JOB not sent"
    fi
    _schedule job "com.jeanlescut.agent-tracker.$JOB" "$JOB.sh every ${INTERVAL}s"
done
JOB="" INTERVAL=""
_schedule com.jeanlescut.agent-tracker.otel com.jeanlescut.agent-tracker.otel "telemetry receiver on 127.0.0.1:4318"
[ -f "$HOME/opt/job-runner/lib.sh" ] || skip "job-runner is not installed (~/opt/job-runner/lib.sh missing): every check fails until it is"

if [ "$OS" != Darwin ] && [ -z "${AGENT_TRACKER_SKIP_LAUNCHD:-}" ]; then
    loginctl enable-linger "$(id -un)" 2>/dev/null || true
fi

step "claude telemetry settings"
# Only the keys in src/claude_telemetry_env.json, inside `env`.
# Takes effect for Claude sessions started after this.
case "$("$PYTHON3" "$SCRIPT_DIR/src/merge_claude_env.py" set)" in
    changed) installed "telemetry env vars in ~/.claude/settings.json (new sessions only)" ;;
    unchanged) ok "telemetry env vars in ~/.claude/settings.json" ;;
    *) fail "telemetry env vars in ~/.claude/settings.json" ;;
esac

step "lifecycle hooks (Claude Code)"
# Our SessionStart / SessionEnd groups only; other tools' groups are kept. New Claude sessions only.
case "$("$PYTHON3" "$SCRIPT_DIR/src/merge_claude_hooks.py" set)" in
    changed) installed "SessionStart / SessionEnd: agent-tracker hook start|end in ~/.claude/settings.json" ;;
    unchanged) ok "SessionStart / SessionEnd hooks in ~/.claude/settings.json" ;;
    *) fail "SessionStart / SessionEnd hooks in ~/.claude/settings.json" ;;
esac

step "lifecycle hooks (Codex)"
# Codex has no settings file to edit: the hooks ship as a plugin (src/codex-plugin/), published
# through a local marketplace, both registered in ~/.codex/config.toml by Codex's own idempotent
# `codex plugin` commands (agent-session-manager's install.sh does the same for its hooks).
if [ -n "$CODEX_BIN" ] && [ -x "$CODEX_BIN" ]; then
    codex_same=false
    diff -rq "$SCRIPT_DIR/src/codex-plugin" "$RUNTIME/codex-plugin" >/dev/null 2>&1 \
        && [ -f "$RUNTIME/codex-marketplace/.agents/plugins/marketplace.json" ] && codex_same=true
    rm -rf "$RUNTIME/codex-plugin"
    mkdir -p "$RUNTIME/codex-plugin" "$RUNTIME/codex-marketplace/.agents/plugins" "$RUNTIME/codex-marketplace/plugins"
    cp -R "$SCRIPT_DIR/src/codex-plugin/." "$RUNTIME/codex-plugin/"
    ln -sfn "$RUNTIME/codex-plugin" "$RUNTIME/codex-marketplace/plugins/agent-tracker"
    cat > "$RUNTIME/codex-marketplace/.agents/plugins/marketplace.json" <<EOF
{
  "name": "agent-tracker-local",
  "interface": {"displayName": "agent-tracker (local)"},
  "plugins": [
    {
      "name": "agent-tracker",
      "source": {"source": "local", "path": "./plugins/agent-tracker"},
      "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
      "category": "Productivity"
    }
  ]
}
EOF
    if "$CODEX_BIN" plugin marketplace add "$RUNTIME/codex-marketplace" >/dev/null 2>&1 && \
       "$CODEX_BIN" plugin add agent-tracker@agent-tracker-local >/dev/null 2>&1; then
        if $codex_same; then ok "Codex plugin agent-tracker@agent-tracker-local"
        else installed "agent-tracker@agent-tracker-local in ~/.codex/config.toml (Codex asks once to trust its hooks)"; fi
    else
        fail "Codex plugin not registered; by hand: codex plugin marketplace add $RUNTIME/codex-marketplace && codex plugin add agent-tracker@agent-tracker-local"
    fi
else
    skip "Codex not found: no Codex hooks"
fi

echo ""
