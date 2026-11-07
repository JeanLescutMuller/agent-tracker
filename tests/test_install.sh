#!/bin/bash
# End-to-end tests for install.sh and uninstall.sh, run against a temp $HOME
# so nothing ever touches the real machine. AGENT_TRACKER_SKIP_LAUNCHD
# keeps both off the real gui/$(id -u) launchd domain, which a HOME override
# can't sandbox.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

# A fake `codex` (never the real one): records its arguments in $HOME/codex.log.
make_fake_codex() {
    mkdir -p "$1/fakebin"
    printf '#!/bin/bash\necho "$*" >> "%s/codex.log"\n' "$1" > "$1/fakebin/codex"
    chmod +x "$1/fakebin/codex"
}
run_script() {
    local script="$1" home="$2" err_file
    [ -x "$home/fakebin/codex" ] || make_fake_codex "$home"
    err_file="$(mktemp "${TMPDIR:-/tmp}/th-err.XXXXXX")"
    TH_OUT="$(HOME="$home" AGENT_TRACKER_SKIP_LAUNCHD=1 AGENT_TRACKER_CODEX_BIN="${CODEX_BIN_OVERRIDE:-$home/fakebin/codex}" \
        bash "$REPO_ROOT/$script" 2>"$err_file")"
    TH_STATUS=$?
    TH_ERR="$(cat "$err_file")"
    rm -f "$err_file"
}
new_home() { mktemp -d "${TMPDIR:-/tmp}/agent-usage-tracker-installhome.XXXXXX"; }

section "install deploys the ingest script, gates, collectors, the job entrypoints and their LaunchAgents"
th_home="$(new_home)"
RT="$th_home/opt/agent-tracker"
run_script install.sh "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
assert_file_missing "no bin/ any more: agent-statusline runs the reader itself" "$RT/bin"
for f in usage_db.py ingest_account_quota.py ingest_session_usage.py statusline_payload_reader.py statusline_usage.py agent_tracker.py \
    claude_quota_api_poller.py codex_quota_api_poller.py codex_plan_history_poller.py \
    telemetry_receiver.py transcript_reader.py; do
    assert_file_exists "$f deployed" "$RT/src/$f"
done
assert_eq "the reader runs directly: this machine's python, -S" "#!$(command -v python3) -S" "$(head -1 "$RT/src/statusline_payload_reader.py")"
assert_not_contains "...with this machine's name filled in" "$(cat "$RT/src/statusline_payload_reader.py")" 'MACHINE_NAME = "__MACHINE_NAME__"'
[ -x "$RT/src/statusline_payload_reader.py" ]
assert_status "...and executable" 0 $?
assert_file_missing "no database before the first write" "$RT/data/claude/account_quotas.db"
assert_file_exists "data/claude/ created" "$RT/data/claude"
assert_file_exists "data/codex/ created" "$RT/data/codex"
assert_file_missing "adhoc_quotas_analysis/ is run-by-hand, never deployed" "$RT/adhoc_quotas_analysis"
for job in claude-quota:60 codex-quota:60 codex-plan-history:3600 aggregates:300; do
    label="com.jeanlescut.agent-tracker.${job%%:*}"
    assert_file_exists "${job%%:*}.sh entrypoint deployed" "$RT/${job%%:*}.sh"
    assert_contains "$label runs its entrypoint with /bin/bash" "$(cat "$RT/$label.plist")" \
        "<string>/bin/bash</string>
        <string>$RT/${job%%:*}.sh</string>"
    assert_contains "$label every ${job#*:}s" "$(cat "$RT/$label.plist")" "<integer>${job#*:}</integer>"
    assert_eq "$label symlinked into ~/Library/LaunchAgents" "$RT/$label.plist" "$(readlink "$th_home/Library/LaunchAgents/$label.plist")"
done
assert_file_missing "no single pollers trigger any more" "$RT/com.jeanlescut.agent-tracker.plist"
assert_not_contains "placeholders all rendered" "$(cat "$RT"/*.plist)" "__"
assert_file_missing "the settings merge helper runs from the repo, never deployed" "$RT/src/merge_claude_env.py"
assert_file_missing "...so does the hooks merge helper" "$RT/src/merge_claude_hooks.py"
assert_eq "agent-tracker on the PATH: a link to the deployed command" "$RT/src/agent_tracker.py" "$(readlink "$th_home/.local/bin/agent-tracker")"
assert_eq "the command runs directly: this machine's python, -S" "#!$(command -v python3) -S" "$(head -1 "$RT/src/agent_tracker.py")"
assert_not_contains "...with this machine's name filled in" "$(cat "$RT/src/agent_tracker.py")" 'MACHINE_NAME = "__MACHINE_NAME__"'
assert_file_exists "data/sessions/ created" "$RT/data/sessions"
assert_contains "SessionStart hook registered" "$(jq -r '.hooks.SessionStart[].hooks[].command' "$th_home/.claude/settings.json")" "agent-tracker hook start"
assert_contains "SessionEnd hook registered" "$(jq -r '.hooks.SessionEnd[].hooks[].command' "$th_home/.claude/settings.json")" "agent-tracker hook end"
assert_contains "Codex: the local marketplace added" "$(cat "$th_home/codex.log")" "plugin marketplace add $RT/codex-marketplace"
assert_contains "Codex: the plugin added" "$(cat "$th_home/codex.log")" "plugin add agent-tracker@agent-tracker-local"
assert_contains "Codex: its hooks run agent-tracker hook --agent codex" "$(cat "$RT/codex-marketplace/plugins/agent-tracker/hooks/hooks.json")" "agent-tracker hook start --agent codex"
assert_eq "Codex: the marketplace names the plugin" "agent-tracker" "$(jq -r '.plugins[0].name' "$RT/codex-marketplace/.agents/plugins/marketplace.json")"
assert_contains "receiver plist keeps it alive" "$(cat "$RT/com.jeanlescut.agent-tracker.otel.plist")" "<key>KeepAlive</key>"
assert_eq "receiver plist symlinked into ~/Library/LaunchAgents" "$RT/com.jeanlescut.agent-tracker.otel.plist" \
    "$(readlink "$th_home/Library/LaunchAgents/com.jeanlescut.agent-tracker.otel.plist")"
assert_file_missing "no systemd units on macOS" "$th_home/.config/systemd"
assert_eq "telemetry env vars merged into ~/.claude/settings.json" \
    "$(jq -cS . "$REPO_ROOT/src/claude_telemetry_env.json")" "$(jq -cS .env "$th_home/.claude/settings.json")"
assert_file_missing "nothing of agent-statusline's is created" "$th_home/opt/agent-statusline"

section "idempotent re-run"
run_script install.sh "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
assert_not_contains "nothing re-installed on an unchanged re-run" "$TH_OUT" "[+]"
assert_eq "still one SessionStart and one SessionEnd group" "1 1" \
    "$(jq -r '[(.hooks.SessionStart | length), (.hooks.SessionEnd | length)] | join(" ")' "$th_home/.claude/settings.json")"

section "the deployed agent-tracker: tick through the PATH link, into the deployed runtime"
printf '{"type":"assistant","timestamp":"2026-01-01T10:00:00Z"}\n' > "$th_home/t2.jsonl"
payload="$(printf '{"session_id":"u-install","cwd":"/x","transcript_path":"%s","rate_limits":{"five_hour":{"used_percentage":21,"resets_at":1788091200}}}' "$th_home/t2.jsonl")"
out="$(printf '%s' "$payload" | env HOME="$th_home" "$th_home/.local/bin/agent-tracker" tick)"
assert_eq "stdout is stdin" "$payload" "$out"
assert_eq "last_seen.json in the deployed runtime" "u-install" "$(jq -r .uuid "$RT/data/sessions/u-install/last_seen.json")"
assert_eq "quota_latest.json in the deployed runtime" "21" "$(jq -r .five_hour.used_percentage "$RT/data/claude/quota_latest.json")"
assert_eq "...the machine name filled in at install" "$(cd "$REPO_ROOT/src" && python3 -c 'import usage_db; print(usage_db.machine_name())')" \
    "$(jq -r .machine "$RT/data/claude/quota_latest.json")"
th_run env HOME="$th_home" "$th_home/.local/bin/agent-tracker" check
assert_status "check: exit 1 (no statusLine chain: my-setup's)" 1 "$TH_STATUS"
assert_contains "...says so" "$TH_OUT" "statusLine"
assert_not_contains "...but the hooks are there" "$TH_OUT" "hook SessionStart not registered"
rm -rf "$RT/data/sessions/u-install" "$RT/data/claude/quota_latest.json" "$RT/data/claude/account_quotas.db"* "$RT/data/claude/sessions_usages.db"*

section "the deployed reader writes into the deployed runtime's databases, and prints the reading"
printf '{"type":"assistant","timestamp":"2026-01-01T10:00:00Z"}\n' > "$th_home/t.jsonl"
out="$(printf '{"transcript_path":"%s","session_id":"s1","rate_limits":{"five_hour":{"used_percentage":12}}}' "$th_home/t.jsonl" \
    | env HOME="$th_home" "$RT/src/statusline_payload_reader.py")"
assert_eq "one account row" "1" \
    "$(python3 -c "import sqlite3; print(sqlite3.connect('$RT/data/claude/account_quotas.db').execute('SELECT COUNT(*) FROM account_quotas').fetchone()[0])")"
assert_eq "its reading printed" "12" "$(cut -d $'\034' -f1 <<< "$out")"
assert_file_missing "no state file" "$RT/state/quota/claude"
rm -rf "$th_home"

section "telemetry env merge leaves every other settings key alone"
th_home="$(new_home)"
mkdir -p "$th_home/.claude"
printf '{"theme":"dark","env":{"MY_VAR":"keep","OTEL_LOGS_EXPORTER":"console"}}\n' > "$th_home/.claude/settings.json"
run_script install.sh "$th_home"
assert_eq "other top-level keys untouched" "dark" "$(jq -r .theme "$th_home/.claude/settings.json")"
assert_eq "other env keys untouched" "keep" "$(jq -r .env.MY_VAR "$th_home/.claude/settings.json")"
assert_eq "an owned key is set to our value" "otlp" "$(jq -r .env.OTEL_LOGS_EXPORTER "$th_home/.claude/settings.json")"
# A value changed by hand after install is someone else's now - must survive.
jq '.env.OTEL_EXPORTER_OTLP_ENDPOINT = "http://elsewhere:4318"' "$th_home/.claude/settings.json" > "$th_home/s.tmp" \
    && mv "$th_home/s.tmp" "$th_home/.claude/settings.json"
run_script uninstall.sh "$th_home"
assert_eq "uninstall removes only our unchanged env keys" \
    '{"MY_VAR":"keep","OTEL_EXPORTER_OTLP_ENDPOINT":"http://elsewhere:4318"}' \
    "$(jq -cS .env "$th_home/.claude/settings.json")"
rm -rf "$th_home"

section "uninstalling a fresh install removes everything"
th_home="$(new_home)"
mkdir -p "$th_home/.claude"
printf '{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"other-tool start"}]}]}}\n' > "$th_home/.claude/settings.json"
run_script install.sh "$th_home"
assert_eq "install: another tool's SessionStart group kept, ours added" "other-tool start|agent-tracker" \
    "$(jq -r '[.hooks.SessionStart[].hooks[].command] | map(sub(".*/"; "")) | map(sub(" hook start"; "")) | join("|")' "$th_home/.claude/settings.json")"
run_script uninstall.sh "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
assert_eq "uninstall: only our hook groups removed" '{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"other-tool start"}]}]}' \
    "$(jq -c .hooks "$th_home/.claude/settings.json")"
assert_file_missing "the agent-tracker link removed" "$th_home/.local/bin/agent-tracker"
assert_contains "Codex plugin removed" "$(cat "$th_home/codex.log")" "plugin remove agent-tracker@agent-tracker-local"
assert_contains "...and its marketplace" "$(cat "$th_home/codex.log")" "plugin marketplace remove agent-tracker-local"
for label in com.jeanlescut.agent-tracker.otel com.jeanlescut.agent-tracker.claude-quota com.jeanlescut.agent-tracker.codex-quota \
    com.jeanlescut.agent-tracker.codex-plan-history com.jeanlescut.agent-tracker.aggregates; do
    assert_file_missing "$label symlink removed" "$th_home/Library/LaunchAgents/$label.plist"
done
assert_file_missing "the whole runtime dir is gone when data/ was never populated" "$th_home/opt/agent-tracker"
assert_not_contains "no orphans reported" "$TH_OUT" "orphan files/dirs under"
rm -rf "$th_home"

section "uninstall preserves data/ and flags an unknown leftover"
th_home="$(new_home)"
RT="$th_home/opt/agent-tracker"
run_script install.sh "$th_home"
printf 'db' > "$RT/data/claude/account_quotas.db"
mkdir -p "$RT/mystery-dir"
run_script uninstall.sh "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
assert_file_exists "data/ survives" "$RT/data/claude/account_quotas.db"
assert_contains "reports preserving data/" "$TH_OUT" "preserved"
assert_file_missing "deployed code gone" "$RT/src"
assert_contains "names the orphan" "$TH_OUT" "mystery-dir"
assert_file_exists "the orphan is left untouched" "$RT/mystery-dir"
rm -rf "$th_home"

section "no Codex on the machine: no Codex hooks, the rest installs"
th_home="$(new_home)"
CODEX_BIN_OVERRIDE=/nonexistent/codex run_script install.sh "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
assert_contains "says why" "$TH_OUT" "Codex not found"
assert_file_missing "no plugin deployed" "$th_home/opt/agent-tracker/codex-plugin"
rm -rf "$th_home"

section "the old runtime still holds data/: install refuses (the move is a deploy step)"
th_home="$(new_home)"
mkdir -p "$th_home/opt/agent-usage-tracker/data/claude"
run_script install.sh "$th_home"
assert_status "exits 1" 1 "$TH_STATUS"
assert_contains "points at doc/deploy_migration.md" "$TH_OUT" "doc/deploy_migration.md"
assert_file_missing "nothing deployed" "$th_home/opt/agent-tracker/src"
mv "$th_home/opt/agent-usage-tracker/data" "$th_home/opt/agent-tracker-data-moved" && mkdir -p "$th_home/opt/agent-tracker" \
    && mv "$th_home/opt/agent-tracker-data-moved" "$th_home/opt/agent-tracker/data"
run_script install.sh "$th_home"
assert_status "once moved, it installs" 0 "$TH_STATUS"
rm -rf "$th_home"

section "uninstall keeps data/sessions/ once written"
th_home="$(new_home)"
run_script install.sh "$th_home"
mkdir -p "$th_home/opt/agent-tracker/data/sessions/u1" && printf '{}\n' > "$th_home/opt/agent-tracker/data/sessions/u1/last_seen.json"
run_script uninstall.sh "$th_home"
assert_file_exists "data/sessions/ survives" "$th_home/opt/agent-tracker/data/sessions/u1/last_seen.json"
rm -rf "$th_home"

section "uninstalling an already-clean machine is a harmless no-op"
th_home="$(new_home)"
run_script uninstall.sh "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
rm -rf "$th_home"

section "Linux (the VM): systemd --user units instead of LaunchAgents"
th_home="$(new_home)"
RT="$th_home/opt/agent-tracker"
UNITS="$th_home/.config/systemd/user"
TH_OUT="$(HOME="$th_home" AGENT_TRACKER_SKIP_LAUNCHD=1 AGENT_TRACKER_OS=Linux AGENT_TRACKER_CODEX_BIN=/nonexistent bash "$REPO_ROOT/install.sh" 2>&1)"
assert_status "exits 0" 0 $?
assert_file_missing "no LaunchAgents" "$th_home/Library/LaunchAgents"
for unit in com.jeanlescut.agent-tracker.claude-quota.service com.jeanlescut.agent-tracker.claude-quota.timer \
    com.jeanlescut.agent-tracker.otel.service \
    com.jeanlescut.agent-tracker.aggregates.service com.jeanlescut.agent-tracker.aggregates.timer; do
    assert_eq "$unit: real file in the runtime, symlink in ~/.config/systemd/user" "$RT/$unit" "$(readlink "$UNITS/$unit")"
done
assert_contains "a job's service runs its entrypoint with /bin/bash" \
    "$(cat "$RT/com.jeanlescut.agent-tracker.aggregates.service")" "ExecStart=/bin/bash $RT/aggregates.sh"
assert_file_exists "aggregates.sh entrypoint deployed" "$RT/aggregates.sh"
assert_file_missing "no push job any more (the aggregates job sends)" "$RT/push.sh"
assert_file_missing "no Codex jobs on Linux" "$RT/com.jeanlescut.agent-tracker.codex-quota.service"
assert_file_missing "no Codex entrypoint on Linux" "$RT/codex-quota.sh"
assert_not_contains "placeholders all rendered" "$(cat "$RT"/*.service "$RT"/*.timer)" "__"
assert_contains "the receiver restarts if it exits" "$(cat "$RT/com.jeanlescut.agent-tracker.otel.service")" "Restart=always"
assert_contains "claude-quota ticks every 60s" "$(cat "$RT/com.jeanlescut.agent-tracker.claude-quota.timer")" "OnUnitActiveSec=60s"
assert_contains "aggregates every 5 min" "$(cat "$RT/com.jeanlescut.agent-tracker.aggregates.timer")" "OnUnitActiveSec=300s"
mkdir -p "$RT/data/claude/aggregates" && printf 'db' > "$RT/data/claude/aggregates/some-mac.db" && printf 'db' > "$RT/data/claude/intermediary.db"
TH_OUT="$(HOME="$th_home" AGENT_TRACKER_SKIP_LAUNCHD=1 AGENT_TRACKER_OS=Linux AGENT_TRACKER_CODEX_BIN=/nonexistent bash "$REPO_ROOT/uninstall.sh" 2>&1)"
assert_eq "uninstall removes the unit symlinks" "" "$(ls "$UNITS" 2>/dev/null)"
assert_file_exists "every machine's slots survive (data/claude/aggregates/)" "$RT/data/claude/aggregates/some-mac.db"
assert_file_missing "the intermediary tables go (rebuilt from the transcripts)" "$RT/data/claude/intermediary.db"
assert_not_contains "no orphans" "$TH_OUT" "orphan files"
rm -rf "$th_home"

harness_summary
