# Deploy: agent-usage-tracker → agent-tracker (v1, branch `agent-tracker-v1`)

What the real deploy must do, once, on each machine. Nothing here was run on a real machine: the build ran only in sandboxes (`~/dev/agent-tracker/IMPLEMENTATION.md` §1). `install.sh` carries no migration logic (`AGENTS.md`, "Install, deploy"): it **refuses to run** while `~/opt/agent-usage-tracker/data` exists and `~/opt/agent-tracker/data` does not, so step 3 below cannot be skipped by mistake.

## What changes

| | Before | After |
|---|---|---|
| repo, `~/dev` folder | `agent-usage-tracker` | `agent-tracker` (rename on GitHub, then `git remote set-url`, `mv ~/dev/agent-usage-tracker ~/dev/agent-tracker`) |
| deploy root | `~/opt/agent-usage-tracker` | `~/opt/agent-tracker` |
| triggers | `com.jeanlescut.agent-usage-tracker.{claude-quota,aggregates,codex-quota,codex-plan-history,otel}` | `com.jeanlescut.agent-tracker.*` (same jobs) |
| job-runner job names | `agent-usage-tracker.<job>` | `agent-tracker.<job>` |
| statusline | agent-statusline pipes each payload to `~/opt/agent-usage-tracker/src/statusline_payload_reader.py` | my-setup's `statusLine` = `agent-tracker tick \| display`; the display reads `data/claude/quota_latest.json` |
| "a status line on screen" (quota jobs) | `~/opt/agent-statusline/state/heartbeat/{claude,codex}` | newest `data/sessions/*/last_seen.json` |
| new | — | `~/.local/bin/agent-tracker`; SessionStart / SessionEnd hooks in `~/.claude/settings.json`; Codex plugin `agent-tracker@agent-tracker-local` (Mac) |
| VM paths the Mac calls over ssh | `~/opt/agent-usage-tracker/src/{ingest_account_quota,receive_from_machine}.py` | `~/opt/agent-tracker/src/…` |

## Order

```
1 VM first ──▶ 2 Mac, within 30 min ──▶ 3 the other repos (statusline switch) ──▶ 4 check
  (the Mac's old code calls the VM's old paths: the sync and the send fail meanwhile; the sync turns
   the job red only after 30 min, the send keeps its watermark and resends: nothing is lost)
```

## Per machine (VM, then Mac)

| # | Step | Command (Mac; VM the same with `systemctl`, done by the same scripts) |
|---|---|---|
| 1 | Stop and remove the old triggers (telemetry receiver included: the new one binds the same port 4318) | `for j in claude-quota aggregates codex-quota codex-plan-history otel; do python3 ~/dev/agent-tracker/adhoc_quotas_analysis/migrate_to_target.py remove-trigger $j; done` (its `--runtime` defaults to the old tree, its labels are the old ones; VM: no Codex jobs, harmless). Never the old `uninstall.sh`: it removes the telemetry `env` keys and `state/` |
| 2 | Move the data and the state (watermarks of the sync and the send: without them, everything is resent) | `mkdir -p ~/opt/agent-tracker && mv ~/opt/agent-usage-tracker/data ~/opt/agent-tracker/data && mv ~/opt/agent-usage-tracker/state ~/opt/agent-tracker/state` (one filesystem: renames; WAL files move with their databases) |
| 3 | Install | `bash ~/dev/agent-tracker/install.sh` (VM: rsync the repo to `~/dev/agent-tracker` there first) |
| 4 | Right away, bridge the old statusline reader (still run by the old display until the statusline switch, step 3 of "Order") to the new code, so its readings land in the new tree (verified in a sandbox: a symlinked wrapper writes into `~/opt/agent-tracker`) | `ln -sf ~/opt/agent-tracker/src/statusline_payload_reader.py ~/opt/agent-usage-tracker/src/statusline_payload_reader.py` |
| 5 | Dashboard: the old job names are gone | on the VM, for each old job: `f=~/opt/job-runner/conf/agent-usage-tracker.<job>.conf; { cat $f 2>/dev/null; echo DECOMMISSIONED=1; } > $f.new && mv -f $f.new $f` (skill jobs-and-services §4) |
| 6 | Codex (Mac) | start one `codex` session and approve agent-tracker's hooks once |
| 7 | Leftovers | look at what remains in `~/opt/agent-usage-tracker/` (`src/`, `logs/`, plists already removed), then delete it by hand, file by file; remove the bridge of step 4 with it, once the statusline is switched |

## The other repos (each its own worktree on `agent-tracker-v1`)

| Repo | Must | Why |
|---|---|---|
| my-setup | deploy the `statusLine` chain `agent-tracker tick \| bash ~/.claude/statusline-command.sh`; update the skill config-ownership: `hooks` groups whose command contains `agent-tracker hook ` are agent-tracker's, the telemetry `env` keys are owned by agent-tracker | `agent-tracker check` reports a statusLine that does not start with `agent-tracker tick` |
| agent-statusline | deploy the display that reads `quota_latest.json` and writes no heartbeat | the quota jobs no longer read the heartbeat |
| job-applications (auto-job-apply) | `runner/limits.py`: the database path `~/opt/agent-tracker/data/claude/account_quotas.db` | it reads the view `latest` there |
| job-runner | its `examples/agent-usage-tracker/` copies of the entrypoints and `doc/examples.md`: the new name and `claude-quota.sh`'s `last-seen-age` line | job-runner tests them |
| tasks, my-context (`projects.md`), secrets-and-account-migration | the name and paths | they mention the old ones |
| Todoist | this repo's tasks carry `Repo: agent-usage-tracker`: rename the label text, then `todo.html` | `AGENTS.md` points there |

Until the statusline is switched, `tick` is not running: no `last_seen.json`, so the quota jobs use their idle thresholds (300 s Mac, 480 s VM) and `agent-tracker check` reports every open Claude session. Claude sessions opened before the deploy have no start line until they are restarted (the hooks load at start).

## Check (each machine)

```bash
agent-tracker check          # "all good" once the statusline chain is deployed and the open Claude sessions restarted
agent-tracker now            # every open Claude session, with its pane
ls ~/opt/agent-usage-tracker/data 2>/dev/null   # empty, or only the few seconds of readings between steps 2 and 4 (statusline duplicates: safe to drop)
```

Not verified before the deploy: the Linux code paths of `agent_tracker.py` (`/proc/<pid>/stat`, `/proc/stat` btime, `/proc/<pid>/cmdline`; the Mac uses libproc / sysctl, tested) - on the VM, run one `agent-tracker tick < payload` by hand and look at `pid`, `pid_start`, `boot_ts` in its `last_seen.json`; whether Claude Code's statusline ticks while its pane is hidden (`~/dev/agent-tracker/DESIGN.md`, open points).
