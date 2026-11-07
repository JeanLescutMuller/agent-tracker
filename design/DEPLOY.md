# Deploy — agent-tracker v1 (deployed 2026-11-07)

**Status (2026-11-07, 17:10 CET):** deployed on the Mac and the VM, in the order below, by claude-code (session cbf1952e). Repos renamed on GitHub and in `~/dev` (agent-usage-tracker → agent-tracker, agent-session-manager → agent-resume); the design repo folded into `design/` (history kept).

**Leftovers done (2026-11-07, 18:15 CET, same session, each with the user's yes):** job-applications and job-runner redeployed (auto-job-apply reads `~/opt/agent-tracker/data`); the compatibility link `~/opt/agent-usage-tracker/data` and the folder `~/opt/agent-usage-tracker/` removed on the Mac and the VM, after checking nothing reads them; `~/opt/agent-session-manager/` archived to `~/opt/agent-resume/data/archive/2026_11_07_agent-session-manager_data_<machine>.tar.gz` (Mac 441 files, VM 34), then removed; old names out of job-runner's docs and test (its examples test had 14 failures from the rename, 31/31 now) and out of 6 Todoist titles; every repo pushed; agent-auto-close on GitHub (public).

**Incident, 15:30 CET:** a test agent killed the user's real tmux server (`TMUX_TMPDIR=$d tmux kill-server` with `TMUX` set: tmux ignores TMUX_TMPDIR). It revealed: `tick` overwrote the pane fields with nulls once tmux was gone (fixed: kept, `tests/test_tick_tmux_gone.sh`); `ares tmux` handled a reboot only (added `--this-boot`); the iTerm2 tabs failed in zsh (`=name`, fixed: quoted). The user restored with `ares tmux --this-boot`. Rule since: tests run tmux only through `tests/tmux_guard.sh`. Later fixes: last prompt in long transcripts, `check` skips SDK processes, agent-auto-close skips non-typed entries, three restore bugs (6+ panes, reboot after a tmux death, resumed-then-exited). Open items: Todoist, subsections agent-tracker and agent-resume.

The plan as it was written before the deploy:

Everything is built and tested on branch `agent-tracker-v1` in each repo (agent-auto-close: its new repo's `main`); nothing is merged, pushed, installed or renamed. This file gives the order across repos; each repo's own deploy note has the exact commands. Built and tested 2026-11-07; see "Status" in [`IMPLEMENTATION.md`](IMPLEMENTATION.md).

## Review first

```bash
for r in agent-usage-tracker agent-session-manager agent-notify agent-statusline my-setup; do
  git -C /Users/jeanlescut/dev/$r log --oneline main..agent-tracker-v1; done
git -C /Users/jeanlescut/dev/agent-auto-close log --oneline
bash /Users/jeanlescut/dev/agent-tracker/tests/integration.sh      # 38 checks, sandbox only
```

All five branches merge into `main` without conflict (checked with `git merge-tree`, 2026-11-07; my-setup's `main` had 2 newer commits).

## Order

| # | Step | Repo · its note | Why this order |
|---|---|---|---|
| 1 | merge `agent-tracker-v1` into `main`, each repo | all | |
| 2 | rename agent-usage-tracker → **agent-tracker** (GitHub, `~/dev` folder), then deploy: **VM first, then the Mac within 30 min** | agent-usage-tracker · `doc/deploy_migration.md` | the data moves to `~/opt/agent-tracker`; the old statusline reader is bridged until step 4 |
| 3 | rename agent-session-manager → **agent-resume**, deploy: VM (hub), then Mac | agent-session-manager · `doc/deploy_migration.md` | needs agent-tracker's lifecycle files; `asm` stays as an alias |
| 4 | agent-statusline `install.sh` (display reads `quota_latest.json`, no heartbeat) | agent-statusline | needs step 2's `quota_latest.json` |
| 5 | `INSTALL=true bash /Users/jeanlescut/dev/my-setup/bootstrap.sh` (statusLine chain, retires cc-map / cc-rc) | my-setup · `doc/deploy_agent_tracker_v1.md` | the chain is written only if agent-tracker is installed |
| 6 | agent-notify `install.sh` (5.15) | agent-notify | no migration; hooks unchanged |
| 7 | agent-auto-close `install.sh` | agent-auto-close | no scheduler yet |
| 8 | Codex: start one `codex` session, approve agent-tracker's and agent-resume's hooks once | — | Codex asks once per plugin |
| 9 | `agent-tracker check`; Claude sessions started before step 2 have no start line until restarted | agent-tracker | |
| 10 | by-hand removals, each after a look (rows marked "by hand" in each note): `~/opt/agent-usage-tracker/` leftovers, `~/opt/agent-session-manager/data/`, cc-rc's log, `~/opt/my-setup/tmux/plugins/`, resurrect snapshots, `~/.tmux/plugins/`, terminal-snapshot's old output, the heartbeat folder | all three notes | nothing reads them any more |
| 11 | other repos, not touched by this build: my-setup's skill config-ownership (hook groups of agent-tracker and agent-resume), auto-job-apply's database path, job-runner's example copies, mentions in tasks / my-context, the Todoist `Repo:` labels | — | outside the five repos |

## Known gaps (not bugs of the build; decisions or open points)

| Gap | Effect | Where decided |
|---|---|---|
| a tmux window with no Claude pane is not restored by `ares tmux` | its plain shells are lost after a crash | agent-tracker records only Claude sessions (DESIGN §4) |
| no `tick` for Codex | no `last_seen.json` for Codex sessions; agent-notify keeps `AGENT_TYPE` for them | Codex's statusline is a patched TUI; open |
| Linux paths (the VM) untested | the deploy's VM step is the first real run | no Linux here |
| agent-notify: one more `tmux list-panes -a` per color update | not timed | agent-notify's report |
| the integration test does not cover agent-notify (a Claude plugin), iTerm2 tabs (`--no-iterm`) or the VM sync | covered only by each repo's own tests | sandbox limits |
