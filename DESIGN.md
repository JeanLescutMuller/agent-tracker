# Design — agent-tracker

**Role (the user, 2026-11-07):** a foundational layer. agent-tracker makes sure the data about Claude sessions is recorded and present; it provides no feature. Features (finding, resuming, restoring after a crash, colors, quotas) live in the projects that use the data. Its only feature is visibility: seeing what runs where (`now`) and whether its own data is being written (`check`). **Merged (the user, 2026-11-07):** agent-tracker is agent-usage-tracker grown and renamed. agent-usage-tracker is already a data layer (its `FOR_READERS.md` rule 1: "Never write. Only this project's gates write its databases"), uses the same trigger (statusline tick) and key (UUID); its databases and jobs stay as they are, the session files are added beside them under `data/sessions/`.

One project, the only writer of the two facts about a Claude session that nobody else keeps and a crash would lose: **where it runs** (pane, PID, folder, last seen) and its **lifecycle** (each start, resume, end). Everything else (prompts, answers, their times, busy/idle) is already kept by Claude Code and is **computed when someone asks**, never copied (option 3, chosen by the user 2026-11-07). Guiding principle: a Unix tool, one job, no overlap. Words: the `## Vocabulary` table of [`AGENTS.md`](AGENTS.md). The page for the user, same content with diagrams: [`design.html`](design.html). Status: proposal, 2026-11-07; nothing is built.

| | |
|---|---|
| Command | writers: `agent-tracker tick` (statusline) · `agent-tracker hook start|end` (SessionStart, SessionEnd) · visibility: `agent-tracker now [--pane %id] [--json]` (what runs where) · `agent-tracker check` (is every writer writing?) |
| Reads | its own files, `~/.claude/sessions/<pid>.json` (live), the end of transcripts, `ps`, `tmux list-panes`, `sysctl kern.boottime` |
| Writes | `~/opt/agent-tracker/data/sessions/<uuid>/last_seen.json` (rewritten ≤ once a minute, by no hook) · `~/opt/agent-tracker/data/sessions/<uuid>/lifecycle.jsonl` (one line per start, resume, end) |
| Triggered by | the statusline tick (every 10 s + each message) and two hooks, SessionStart and SessionEnd (moved from asm, not new). No daemon, no timer |
| Acts | no; ~400 bytes rewritten ≤ once a minute per open Claude session; ~30 lifecycle lines a day in total |
| Consumed by (features, outside agent-tracker) | asm (incl. `asm resume-tmux`, the crash restore), notify, agent-usage-tracker's quota job, cc-map / cc-rc |

## 0. What exists today (measured 2026-11-07, 11:31–12:48, one boot)

Sources: a read-only inventory of the repos (file:line in the inventory report), `launchctl`, the plists in `~/Library/LaunchAgents/`, a 60 s sample of file writes every 0.25 s (12:05), file ages at 12:20, real examples read at 12:40, transcripts of this conversation and of 3 ended Claude sessions. Login was 11:31, so "runs since login" covers 50 min.

| # | Project · stream | Trigger | Interval, theory | In practice | Writes | Survives a crash | Read by (looks up by) | Lag readers see |
|---|---|---|---|---|---|---|---|---|
| 1 | asm · lifecycle | hooks SessionStart, SessionEnd | per event | 0 writes in the 60 s sample | `~/opt/agent-session-manager/data/lifecycles/<uuid>.jsonl` (436 files) | yes | asm index, asm's duplicate check (UUID) | a crashed Claude session stays "pending" for ever (47 at the 11:12 crash) |
| 2 | asm · index | SessionEnd + timer | 1800 s | 2 runs in 50 min | `data/indexes/<uuid>.json` | yes | `asm resume` (text, folder, UUID) | last_active 1085 s behind the transcript at 12:20 |
| 3 | asm · close | read time | when typed | | nothing | | `asm close` | none |
| 4 | notify · per-shell state | hooks SessionStart, UserPromptSubmit, PreToolUse, Stop, Notification, SessionEnd; tmux select-pane; refresh ≤ 300 s piggybacked | per event | state.env 83 s / 114 s old | `/tmp/agent-notify-$USER/<shell_pid>/{static,state}.env` | **no** | notify's renderers (shell PID), cc-map | none; no timestamps kept |
| 5 | statusline · heartbeat | statusline tick | 10 s (`refreshInterval: 10`) + each message | 10 writes / 60 s, gaps 0.8–10.1 s | `~/opt/agent-statusline/state/heartbeat/{claude,codex}`: one time **per agent** | yes | usage quota job (agent type; age < 90 s) | ≤ 10 s |
| 6 | usage · statusline payload | statusline tick | 10 s | 26 writes / 60 s | `data/claude/sessions_usages.db` | yes | its reports (UUID) | ≤ 10 s |
| 7 | usage · OTel | pushed by Claude Code | seconds | always running | same db, telemetry | yes | aggregates | seconds |
| 8 | usage · aggregates | timer | 300 s | 10 runs / 50 min | `data/claude/intermediary.db` | yes | 5-min slots → VM | ≤ 300 s |
| 9 | usage · quota polls | timer | 60 s | 46 runs / 50 min | `account_quotas.db` | yes | statusline | 110–480 s, by design |
| 10 | my-setup · Chrome kit hook | hooks Pre/PostToolUse, UserPromptSubmit, Stop, SubagentStop | per event | 2 writes / 60 s | `~/opt/my-setup/state/chrome/` | yes | the hook, agent-chrome (UUID + subagent) | none; tabs only |
| 11 | my-setup · cc-map, cc-rc | read time | when typed | | nothing | | skill claude-sessions-overview (tmux pane → process tree → pid) | none |
| 12 | my-setup · terminal_snapshot.py | by hand | — | last run 2026-11-01 | `~/.local/state/terminal-snapshot/*_restore.sh` | yes | the user (tmux pane → process tree → pid) | 6 days |
| 13 | my-setup · resurrect + continuum (2026-11-07) | tmux redraw | 300 s | **2 saves in 30 min** | `~/opt/my-setup/state/tmux/resurrect/` | yes | Ctrl-b then Ctrl-r | 20 min; Claude panes come back empty |
| — | Claude Code · `~/.claude/sessions/<pid>.json` | Claude Code, start / busy↔idle / exit | per change | 0 writes / 60 s while busy | pid, sessionId, cwd, tmux `s:@w.%p`, status, updatedAt, name, bridgeSessionId | **no**: 28 files at 12:48, all created after 11:31 | asm close, cc-map, cc-rc, terminal_snapshot | none while it runs |
| — | Claude Code · transcript | each message | — | 3,014 files, 2.5 GB | every prompt and answer with its `timestamp`, a `last-prompt` entry, cwd; **no pane, no PID, no exit entry** (verified on 3 ended Claude sessions) | yes | asm reindex, usage aggregates | — |

## 1. One writer of the facts nobody else keeps

**Choice:** agent-tracker writes only "where it runs" and the lifecycle. Readers get everything else from its source: activity from the transcript, busy/idle from Claude Code's live file. Serves the goal in `AGENTS.md` ("no overlap").

**Why:** "which Claude session is in which pane" is kept in 4 places today and 2 vanish in a crash; nothing keeps "last seen" per Claude session; the transcript already holds every prompt and answer with its time, so copying it would be a fifth overlap.

**Rejected:** keep each project's own tracking (§0: 13 streams, 4 "alive?" rules); an `activity.jsonl` written at every hook (§3: duplicates the transcript).

## 2. Copy only with a reason

| Fact | Claude Code's live file | Transcript | After a crash | agent-tracker keeps it? |
|---|---|---|---|---|
| UUID, pid, folder, tmux pane | yes | folder only | pane, pid gone | yes, `last_seen.json` |
| last seen (while idle too) | updatedAt only on busy↔idle | no | gone | yes, `last_seen.json` ts |
| start, resume, end history | file created / deleted | no exit entry | can't tell from a crash | yes, `lifecycle.jsonl` |
| prompt and answer times, last prompt, title | no | yes | kept | no: read from the transcript |
| busy / idle, name, Remote Control | yes | — | gone (not needed then) | no: read live |
| anything Codex | no such file | its own rollout files | — | yes, same two files |

## 3. Last prompt / last active: computed when asked (option 3)

**Choice:** nothing is written for activity. `agent-tracker now` reads the end of each open Claude session's transcript; `asm resume` re-reads only the transcripts newer than their index entry, then searches as today.

| Option | Writes | Work | Lag | Extra copy |
|---|---|---|---|---|
| 1 · append at every hook | each prompt + each stop, ≈ 40 / hour per active Claude session | one extra process per prompt and per stop (~5 ms each [assumed]) | 0 | yes, a copy of the transcript |
| 2 · index every 5 min | 288 runs / day | each: dates of all transcripts (4 ms [verified]) + re-read the changed ones + ~50 ms Python start [assumed] | ≤ 5 min | yes, the index |
| **3 · when asked (chosen)** | none | per question: dates 4 ms + the end of the changed transcripts; worst case all 3,014 (2.5 GB): 1.85 s [verified 2026-11-07] | 0 | none |

**Why:** no work while nobody asks, no lag, nothing to keep in sync. It can also replace asm's 1800 s job, if the VM sync does not need it (open point).

## 4. Files, and why there are no write collisions

```text
~/opt/agent-tracker/data/sessions/<uuid>/
  last_seen.json   written by `agent-tracker tick` (statusline, every 10 s + each message; no hook writes it);
                   rewritten whole (temp file + rename) only if pane, folder or window layout changed, or once a minute;
                   the layout costs one `tmux display -p '#{window_layout}'` per write
                   {"ts":1794051573,"dt":"2026-11-07T11:39:33Z","agent":"claude","machine":"chan-lescut-macbook-pro",
                    "boot_ts":1794046382,"pid":4607,"pid_start":1794047610,"tmux_session":"jeanlescut",
                    "window_id":"@0","window_index":0,"pane_id":"%0","pane_index":0,"pane":"jeanlescut:0.0",
                    "window_layout":"b25f,208x52,0,0{104x52,0,0,1,103x52,105,0,2}","cwd":"/Users/jeanlescut",
                    "transcript":"~/.claude/projects/-Users-jeanlescut/cbf1952e-….jsonl"}
  lifecycle.jsonl  appended by `agent-tracker hook start|end` (SessionStart, SessionEnd), one line per event, < 512 bytes
                   {"ts":1794047617,"dt":"2026-11-07T10:33:37Z","event":"start","source":"resume","agent":"claude",
                    "machine":"chan-lescut-macbook-pro","boot_ts":1794046382,"pid":4607,"pid_start":1794047610,
                    "pane_id":"%0","pane":"jeanlescut:0.0","cwd":"/Users/jeanlescut"}
                   {"ts":1794050289,"dt":"2026-11-07T11:18:09Z","event":"end","reason":"exit","pid":4607}
```

| Who writes at the same time | Same file? | Why it is safe |
|---|---|---|
| two Claude sessions | no | one folder each |
| two ticks of one Claude session | yes, `last_seen.json` | temp file + `rename`: a reader sees the old or the new file, never half; the last one wins, which is the right answer |
| two hooks of one Claude session (a resume starting while the old process ends) | yes, `lifecycle.jsonl` | one append of < 512 bytes each (`>>`): appended whole, never mixed [assumed, to test on APFS]; ~30 lines a day in total |
| a power cut mid-write | — | rename is all-or-nothing: the old `last_seen.json` stays |

The user's layout (2026-11-07): `last_seen.json` kept as named, written by no hook (a hook would add nothing: the statusline already runs every 10 s; `claude -p` jobs, which have no statusline, still get a `start` line). `lifecycle.jsonl` (the user's point, 2026-11-07) instead of an empty `ended` file: history of starts, resumes and ends, duplicate detection, Claude sessions with no statusline, for ~30 lines a day (measured 245 starts + 158 ends in 14 days; 87 starts never got an end). The crash restore's speed does not matter: 2 crashes in 25 days. `index.json` / `activity.jsonl` dropped (the transcript has it); `usage.jsonl` waits for the scope (§8).

## 5. Reading, and lookups

```text
agent-tracker now   (cc-map, cc-rc, the user)
  for each data/sessions/<uuid>/ whose lifecycle's last event is a start of the current boot:
    alive?       pid running AND its start time == pid_start         # a reused PID does not count
    where?       pane_id -> its place now (tmux list-panes)
    busy/idle?   ~/.claude/sessions/<pid>.json (live)
    last prompt  the end of the transcript (<= 256 KB): last "user" entry

asm resume-tmux, its first step "what was open at the crash" (a feature: it lives in asm and reads the files directly)
  prev_boot = the newest boot_ts that is not the current one
  last_tick = the newest ts among prev_boot's folders                 # ~ the moment of the crash
  each folder whose last lifecycle event is a start in prev_boot, with ts >= last_tick - 2 min   # killed ones stopped ticking
  one per pane_id: the newest ts wins                                  # the pane was reused
```

```text
agent-tracker check   (the user, or a scheduled canary later; visibility of the data itself)
  for each open Claude session (Claude Code's ~/.claude/sessions): has data/sessions/<uuid>/ a start line and a last_seen.json < 2 min old?
  is my-setup's statusLine chained through `agent-tracker tick`? are the two hooks installed?
  -> one line per problem, e.g. "no last_seen.json for 3 open Claude sessions: statusLine not chained on this machine"
```

The data format of §4 is the contract: features read the files directly (or `now --json`); agent-tracker ships no feature code for them.

Every hook and the statusline receive the UUID from Claude Code on stdin, so they open `data/sessions/<uuid>/` directly. Readers that start from a tmux pane use `now --pane <%id>`, which reads the current boot's folders (~30) [assumed cheap; measure in step 2]. No index by pane or PID: one more copy to keep in sync.

| Reader | Starts from | Today | New |
|---|---|---|---|
| asm resume | text, folder or UUID | scans `indexes/*.json` (up to 30 min old) | refreshes changed entries, then scans |
| asm close | a picked Claude session | `~/.claude/sessions/*.json` → pid | unchanged (live) |
| asm duplicate check | UUID | `lifecycles/<uuid>.jsonl` → old pids | `data/sessions/<uuid>/lifecycle.jsonl` → old pids |
| notify hooks | shell PID | `/tmp/agent-notify-$USER/<shell_pid>/` | UUID (hook) → `data/sessions/<uuid>/last_seen.json` → pane |
| cc-map, cc-rc | tmux pane | pane → process tree → `~/.claude/sessions/<pid>.json` | `now --pane` |
| terminal_snapshot → `asm resume-tmux` | the previous boot | pane → process tree → `~/.claude/sessions/<pid>.json` | the previous boot's `data/sessions/*/lifecycle.jsonl` + `last_seen.json`, read directly |
| usage quota job | agent type | `heartbeat/claude` age | newest ts among `data/sessions/*/last_seen.json` |
| usage payload, Chrome kit | UUID | their own stores | unchanged |

## 5b. Use cases: who triggers each command, and how often (measured 2026-11-07)

Each `agent-tracker …` is a command (a small CLI): programs call it with `--json`, the user can type it. Machine = run automatically (hook, statusline, timer); agents = an agent runs it because the user asked something; you = typed by the user. Counts: asm's lifecycle files (14 days), zsh history and agents' transcripts (30 days), usage-tracker's `requests` table (7 days), `~/.claude/sessions` (now).

| Command | What it does | Triggered by | How often [verified] | Reads · writes | Lag that matters |
|---|---|---|---|---|---|
| `agent-tracker tick` | notes where this Claude session is | machine: the statusline, per open Claude session | every 10 s each; 14 open now → up to 5,040 / hour if hidden panes tick too [to test]; writes ≤ 1 / min each | stdin → `last_seen.json` | none |
| `agent-tracker hook start\|end` | logs a start, resume or end | machine: SessionStart, SessionEnd | 17.5 starts + 11 ends / day | stdin → `lifecycle.jsonl` | none |
| notify (no command) | finds its pane | machine: each notify hook (≈ each tool call) | 530–2,880 / day (API requests): the most frequent reader | 1 file, `data/sessions/<uuid>/last_seen.json`, by UUID | must be fast |
| usage quota job (no command) | "is a statusline on screen?" | machine: launchd, 60 s | 1,440 / day | newest `ts` among the current boot's `last_seen.json` | seconds |
| `asm resume` | find and reopen a past Claude session | you · agents | you 33 + agents 19 in 30 days ≈ 1.7 / day | asm's index, refreshed for changed transcripts | the user waits: < 1 s |
| `agent-tracker now` | prints open Claude sessions: pane, folder, busy/idle, last prompt | agents, via cc-map and cc-rc (skill claude-sessions-overview) | cc-map 23 + cc-rc 20 in 30 days ≈ 1.4 / day | ~14 `last_seen.json`, live files, ~14 transcript ends | the user waits: < 1 s |
| `asm resume-tmux` (asm) | finds what was open at the crash, then puts back every tmux session, window and pane size, `claude --resume` in each Claude pane, one iTerm2 tab per tmux session | you, after a crash | 2 in 25 days (today's terminal_snapshot: agents ran it 9 times in 30 days) | the previous boot's `lifecycle.jsonl` + `last_seen.json` → acts on tmux and iTerm2 | none |
| `agent-tracker check` | says whether every writer is writing on this machine (statusLine chained, hooks installed, a fresh `last_seen.json` for each open Claude session) | you, after installing on a machine; later maybe a job-runner canary | new: not measured | `~/.claude/sessions`, `data/`, `~/.claude/settings.json` · writes nothing | none |

So `tick` is the most frequent write and notify the most frequent read: `tick` rewrites `last_seen.json` only when the pane or folder changed, or once a minute (a 1-minute-old position is enough for a restore done every ~2 weeks), and notify reads one file by UUID, never `now`.

## 6. Who owns the statusline call

Claude Code runs one `statusLine` command; the key is owned by my-setup (`modules/claude_config.sh`, skill config-ownership) and points to agent-statusline's script.

**Choice:** my-setup writes `agent-tracker tick | bash ~/.claude/statusline-command.sh` when agent-tracker is installed, the display alone otherwise. `tick` reads the JSON from stdin, writes `last_seen.json` in the background, and copies stdin to stdout unchanged.

**Why:** agent-statusline holds no tracking code, so reinstalling it on a VM, or rewriting the display, cannot drop the tracking.

**Rejected:** a line inside agent-statusline's script (a display rewrite can drop it silently); agent-tracker owning `statusLine` (two projects fighting over one key, last install wins).

| New VM gets | Display | Tracking |
|---|---|---|
| my-setup + agent-statusline | yes | no, nothing breaks |
| + agent-tracker | yes | yes: my-setup chains both |
| agent-statusline reinstalled later | yes | yes: the chain lives in my-setup's setting |

**The statusline as a reader (the user, 2026-11-07):** today the display script pipes every tick's JSON to usage-tracker's `src/statusline_payload_reader.py` (`agent-statusline/providers/claude-statusline-command.sh:59`), which stores it and prints back the account's freshest quota; the display shows it. **Choice:** the storing moves into `agent-tracker tick`; agent-tracker also keeps `data/claude/quota_latest.json` (the freshest 5-hour and weekly %, rewritten when a fresher reading arrives, temp + rename); the display reads that one file. **Why:** the display contains no tracker code and runs no Python per tick; one documented file is the contract. Rate: every 10 s per open Claude session (up to 5,040 / hour with 14 open, if hidden panes tick).

## 7. What each project deletes, and keeps; the crash restore

| Project | Deletes | Keeps |
|---|---|---|
| asm | its SessionStart/SessionEnd hooks and `data/lifecycles/` (moved to agent-tracker's `lifecycle.jsonl`); `session_state` (→ lifecycle); maybe its 1800 s job (→ refresh at search time) | search and its index (decided: stays in asm), VM sync, resume, close; gains `asm resume-tmux` |
| notify | its `/tmp` copy of shell PID, agent PID, pane, UUID, cwd | its states and colors, its own hooks |
| statusline | the per-agent heartbeat (→ newest `last_seen.json` ts); its call to `statusline_payload_reader.py` (→ `tick`) | the display, reading `data/claude/quota_latest.json` |
| usage-tracker | its name (→ agent-tracker); reading the heartbeat | everything else: databases, OTel receiver, aggregates, quota polls, `FOR_READERS.md` |
| my-setup | cc-map/cc-rc's process-tree walk; `tools/terminal_snapshot.py` (→ `asm resume-tmux`); resurrect + continuum (once `asm resume-tmux` works) | the Chrome kit; the `statusLine` chain (§6) |

**The crash restore (decided, the user, 2026-11-07):** it moves to asm as `asm resume-tmux` ("asm finds and resumes: one Claude session or a whole setup"). It reads the previous boot's `lifecycle.jsonl` and `last_seen.json` directly (the rule above), recreates each tmux session and window, applies each window's saved `window_layout` (exact pane sizes), types `claude --resume <uuid>` in each Claude pane, opens plain-shell panes in `~` (their folder is not recorded), and opens one iTerm2 tab per tmux session. **Rejected:** Claude panes only, split evenly (loses pane sizes and plain shells); a full snapshot of tmux and iTerm2 on a timer (exact, but one more writer and 288 runs a day). my-setup's `terminal_snapshot.py` (2026-11-01) and resurrect + continuum (2026-11-07) are removed once it works.

## 8. Scope: what agent-tracker owns, and what stays apart (all decided 2026-11-07)

| Data | In agent-tracker? | If it stays apart | For joining | For staying apart |
|---|---|---|---|---|
| where it runs, lifecycle, last seen | yes, the core | — | copied 4 times today | — |
| asm's search index (title, text) | **no: stays in asm** (decided, the user, 2026-11-07: only `asm resume` uses it, to search faster) | asm, refreshed at search time | | |
| the crash restore | **no: `asm resume-tmux`** (decided, the user, 2026-11-07) | asm | | agent-tracker only says what was where |
| tokens, cost, quotas | **yes: merged** (decided, the user, 2026-11-07) | — | same role (data layer), same tick, same UUID key | — |
| pane colors | no | notify | | display, not tracking |
| Chrome tabs | no | my-setup's Chrome kit | | tabs, not Claude sessions |

## 9. Steps

| # | Step | Touches | Done when |
|---|---|---|---|
| 1 | this design, reviewed | — | the user says yes |
| 1b | rename agent-usage-tracker → agent-tracker (GitHub repo, `~/dev`, `~/opt`, launchd labels, the VM, every reader's path); move these design files into it; this temporary `~/dev/agent-tracker` folder goes, with the user's OK | agent-usage-tracker, agent-statusline, readers | everything works under the new name; `check` is green |
| 2 | `tick` + `hook start|end` + my-setup's chain, beside today's streams; nothing removed | agent-tracker, my-setup | a `data/sessions/<uuid>/` folder with both files for every Claude session, for 2 days |
| 3 | `now` and `check` (agent-tracker); `asm resume-tmux` (asm); then remove `terminal_snapshot.py` and resurrect + continuum | agent-tracker, asm, my-setup | a killed test tmux gets its windows, pane sizes and Claude sessions back |
| 4 | asm: index refreshed at search time; its lifecycle hooks removed (now agent-tracker's); maybe its 1800 s job | asm | `asm resume --state pending` gives the same list, with no lag |
| 5 | notify, cc-map/cc-rc, usage quota job read it; their copies removed | each repo | each one's tests pass |

## Acceptance

- After a crash, `asm resume-tmux` finds exactly the Claude sessions that were open, with their pane, and nothing from older boots.
- On a machine where a writer is missing (e.g. a new VM without the `statusLine` chain), `agent-tracker check` says so.
- `now` agrees with `~/.claude/sessions/*.json` for every live Claude session (same pane, same status), and its last prompt matches the transcript.
- No fact of §2 is stored in two places.

## Open points

- Does Claude Code run the statusline while its pane is hidden (another tmux window)? Decides whether last seen means "open" or "on screen", the 2-min rule of asm resume-tmux's crash step, and the tick count (up to 5,040 / hour with 14 open Claude sessions); test in step 2.
- Does the VM sync still need asm's 1800 s job?
- Codex: statusline interval and SessionEnd hook, not measured (no Codex session today).
- Why continuum saved 2 times in 30 min instead of 6: moot if it is removed.

## Superseded decisions

- 2026-11-07: `events/<uuid>.jsonl` written at 5 hooks → replaced by §3 (computed when asked): the transcript already has every prompt and answer with its time.
- 2026-11-07: `state/events/` + `state/seen/` by kind → replaced by one folder per Claude session (the user's layout).
- 2026-11-07: a `touch` inside agent-statusline's script → replaced by §6 (my-setup chains `tick` before the display).
- 2026-11-07: an empty `ended` file (SessionEnd only) → replaced by `lifecycle.jsonl` (start and end, the user's point): history and duplicate detection for ~30 lines a day; the crash restore's speed does not matter.
- 2026-11-07: `last_seen.json` rewritten at every tick (10 s) → once a minute or on change (§5b: `tick` is the most frequent write).
