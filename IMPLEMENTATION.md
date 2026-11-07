# Implementation contract — agent-tracker v1 (2026-11-07)

The build of [`DESIGN.md`](DESIGN.md) (read it first; its words are in [`AGENTS.md`](AGENTS.md)). Five repos change on one branch, `agent-tracker-v1`, each in its own git worktree; nothing is deployed. This file is the contract between them: file formats, commands, environment variables, and the safety rules. Change it only with the coordinator.

## 1. Safety rules (the user's live setup must not change)

| Never | Instead |
|---|---|
| run `install.sh`, `uninstall.sh`, `bootstrap.sh` or any deploy step with the real `$HOME` | run them only with `HOME=<sandbox>` |
| write under the real `~/opt`, `~/.claude`, `~/.codex`, `~/.local/bin`, `~/Library/LaunchAgents`, crontab; call `launchctl`, `systemctl`, `ssh H-Frank-1` | sandbox paths only (below) |
| run `tmux` against the default server (the user's 14 live Claude sessions) | always `export TMUX_TMPDIR=<sandbox>/tmux` first: a separate tmux server |
| `kill` a process you did not start; `send-keys` to a real pane | fake `claude` = a script you start in the sandbox |
| edit the user's working copies in `~/dev/<repo>` | edit only your worktree (below) |
| `git push`, open PRs, rename GitHub repos | commit on `agent-tracker-v1` in your worktree |

Sandbox: `S=$(mktemp -d)`, then `export HOME=$S/home CLAUDE_CONFIG_DIR=$S/home/.claude AGENT_TRACKER_HOME=$S/home/opt/agent-tracker AGENT_RESUME_HOME=$S/home/opt/agent-resume TMUX_TMPDIR=$S/tmux JR_MACHINE_NAME=test-machine`. Long outputs go to a log file; read only what you need (the user has few tokens).

Every commit ends with the trailers: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, `Agent: claude-code (claude-opus-5-5)`, `Machine: chan-lescut-macbook-pro`, `Session: $CLAUDE_CODE_SESSION_ID`.

## 2. Worktrees (branch `agent-tracker-v1`, from `main`)

`W=/private/tmp/claude-502/-Users-jeanlescut/cbf1952e-21d4-41ec-af21-d33f8a96cbba/scratchpad/wt`

| Repo (today's name → new) | Worktree | What changes |
|---|---|---|
| agent-usage-tracker → **agent-tracker** | `$W/agent-usage-tracker` | adds the session files and the `agent-tracker` command (§3–§5), `quota_latest.json` (§4), deploy root `~/opt/agent-tracker`; quota jobs read last seen instead of the heartbeat |
| agent-session-manager → **agent-resume** | `$W/agent-session-manager` | command `ares` (+ `asm` alias); `ares tmux`; index refreshed at search time; its lifecycle hook and `data/lifecycles/` removed (reads agent-tracker); duplicate warning kept as its own SessionStart hook reading agent-tracker; `status` removed; `close` removed (→ agent-auto-close) |
| (new) **agent-auto-close** | `/Users/jeanlescut/dev/agent-auto-close` (new repo, branch `main`, no remote) | `close` (ported from `asm close`) + `idle` (the policy) |
| agent-statusline | `$W/agent-statusline` | display only: reads `quota_latest.json`; no call to any tracker script; no heartbeat |
| my-setup | `$W/my-setup` | `statusLine` chains `agent-tracker tick \| display`; `terminal_snapshot.py`, resurrect + continuum (`modules/tmux_plugins.sh`, the tmux.conf block) removed; cc-map, cc-rc and the skill claude-sessions-overview parked (moved to `parked/`, no longer deployed) |
| agent-notify | `$W/agent-notify` | stops keeping its own copy of shell PID / agent PID / pane / UUID / cwd where agent-tracker or the hook's own input already gives them |

## 3. Paths

| Variable | Default | Holds |
|---|---|---|
| `AGENT_TRACKER_HOME` | `~/opt/agent-tracker` | `data/sessions/<uuid>/`, `data/claude/` (the usage databases, `quota_latest.json`), `logs/` |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Claude Code's own `sessions/<pid>.json`, `projects/<folder>/<uuid>.jsonl`, `settings.json` |
| `AGENT_RESUME_HOME` | `~/opt/agent-resume` | agent-resume's index and logs |
| `TMUX_TMPDIR` | system | tmux's socket folder (tests: the sandbox) |
| `AGENT_TRACKER_BOOT_TS` | `sysctl -n kern.boottime` (sec) / Linux `/proc/stat` btime | tests set it to simulate a reboot |

## 4. Files (agent-tracker is their only writer)

```text
$AGENT_TRACKER_HOME/data/sessions/<uuid>/last_seen.json      written by `agent-tracker tick`; whole file, temp + rename
{"ts":1794051573,"dt":"2026-11-07T11:39:33Z","agent":"claude","machine":"chan-lescut-macbook-pro","boot_ts":1794046382,
 "uuid":"cbf1952e-…","pid":4607,"pid_start":1794047610,"tmux_session":"jeanlescut","window_id":"@0","window_index":0,
 "window_name":"zsh","pane_id":"%0","pane_index":0,"pane":"jeanlescut:0.0",
 "window_layout":"b25f,208x52,0,0{104x52,0,0,1,103x52,105,0,2}","cwd":"/Users/jeanlescut",
 "transcript":"/Users/jeanlescut/.claude/projects/-Users-jeanlescut/cbf1952e-….jsonl"}
  tmux_* fields are null outside tmux. pid = the Claude Code process (walk up the parent chain from the tick to the first
  pid that has $CLAUDE_CONFIG_DIR/sessions/<pid>.json; else the nearest `claude`/`codex` process). pid_start = that
  process's start time (epoch s). Rewritten only if any field other than ts/dt changed, or ts is ≥ 60 s old.

$AGENT_TRACKER_HOME/data/sessions/<uuid>/lifecycle.jsonl     appended by `agent-tracker hook start|end`; one line < 512 bytes
{"ts":…,"dt":"…","event":"start","source":"startup|resume|clear|compact","agent":"claude","machine":"…","boot_ts":…,
 "pid":4607,"pid_start":…,"pane_id":"%0","pane":"jeanlescut:0.0","cwd":"/Users/jeanlescut"}
{"ts":…,"dt":"…","event":"end","reason":"exit|clear|logout|prompt_input_exit|other","pid":4607}

$AGENT_TRACKER_HOME/data/claude/quota_latest.json           the account's freshest quota reading; temp + rename
{"ts":1794051573,"dt":"…","source":"statusline|poller","machine":"…",
 "five_hour":{"used_percentage":55,"resets_at":1788091200},"seven_day":{"used_percentage":70,"resets_at":1788307200}}
  same shape as Claude Code's statusline `rate_limits`. Rewritten only when a fresher reading arrives (larger ts).
  Readers apply FOR_READERS.md rule 8: a window whose resets_at has passed is at 0%.
```

A reader ignores a line of `lifecycle.jsonl` without its final newline. Fixture of the statusline input: `fixtures/statusline_payload.claude.json` (from agent-statusline's tests). Hook input (Claude Code, stdin): `{"session_id","transcript_path","cwd","hook_event_name","source"}` for SessionStart, `"reason"` for SessionEnd; asm's `src/lifecycle_generation.sh` parses the same.

## 5. Commands

| Command | Contract |
|---|---|
| `agent-tracker tick` | stdin: the statusline JSON. Writes `last_seen.json` (§4), runs the usage recording that `src/statusline_payload_reader.py` does today (minus printing a line), updates `quota_latest.json` from the payload's `rate_limits` when fresher. **Copies stdin to stdout byte for byte.** Never fails: any error → `logs/tick-errors.log`, exit 0. Budget: < 150 ms. |
| `agent-tracker hook start` / `hook end` [`--agent codex`] | stdin: the hook JSON. Appends one line. Prints **nothing** (SessionStart stdout would enter Claude's context). Exit 0 always. |
| `agent-tracker now [--pane %id] [--uuid U] [--json]` | open Claude sessions of the current boot: last lifecycle event is a start, pid alive with matching pid_start. Per row: uuid, pane (resolved now by pane_id through tmux), cwd, status (from `$CLAUDE_CONFIG_DIR/sessions/<pid>.json`), last_prompt (the end of the transcript: last `user` entry that is not a tool result), last_seen. |
| `agent-tracker check` | one line per problem, exit 1 if any: an open Claude session (from `$CLAUDE_CONFIG_DIR/sessions`) with no folder, no start line, or `last_seen.json` older than 2 min; `statusLine` in `$CLAUDE_CONFIG_DIR/settings.json` not starting with `agent-tracker tick`; the two hooks not registered. "all good" and exit 0 otherwise. |
| `ares tmux [--dry-run] [--all] [--no-iterm]` (agent-resume) | crash restore. Previous boot = newest `boot_ts` among `data/sessions/*/` that is not the current one. Candidates: Claude sessions whose last lifecycle event is a start in that boot; per `pane_id` keep the newest; mark **stale** those whose `last_seen.ts` is more than 2 min older than the boot's newest `last_seen.ts` (restored only with `--all`). Recreate each tmux session and window (names, indexes), apply `window_layout` with `select-layout`, start `claude --resume <uuid>` in its pane (cwd), plain panes in `~`, then one iTerm2 tab per tmux session (AppleScript; `--no-iterm` skips). `--dry-run` prints the plan. Never touches a tmux session that already exists (prints it as skipped). |
| `agent-auto-close close <uuid\|%pane>` · `agent-auto-close idle --over <hours> [--dry-run]` | close = `asm close` today (capture pane, SIGTERM, screen file, pre-typed `claude --resume`), refusing busy, self, non-tmux. idle = list (or close) Claude sessions idle for longer than N hours (status idle and last prompt older than N h). No scheduler installed. |

## 6. Done, per repo

- Its own test suite passes, plus new tests for what changed, all in the sandbox; a short `TESTING.md` note (or the repo's existing test README) says how to run them.
- Docs updated in the repo's own conventions (README / AGENTS.md / FOR_READERS.md), using the four names.
- One or more commits on `agent-tracker-v1` (agent-auto-close: `main`), never pushed.
- A report to the coordinator, ≤ 300 words: what changed (files), test results (numbers), what was left out and why, anything the deploy step must do (migrations, renames).
