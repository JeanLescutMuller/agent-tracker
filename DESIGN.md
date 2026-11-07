# Design — agent-tracker

One project, the only writer of the two facts about a Claude session that nobody else keeps and a crash would lose: **where it runs** (pane, PID, folder, last seen) and **whether it ended**. Everything else (prompts, answers, their times, busy/idle) is already kept by Claude Code and is **computed when someone asks**, never copied (option 3, chosen by the user 2026-11-07). Guiding principle: a Unix tool, one job, no overlap. Words: the `## Vocabulary` table of [`AGENTS.md`](AGENTS.md). The page for the user, same content with diagrams: [`design.html`](design.html). Status: proposal, 2026-11-07; nothing is built.

| | |
|---|---|
| Command | `agent-tracker tick` (statusline) · `agent-tracker end` (SessionEnd hook) · `agent-tracker now [--pane %id] [--json]` · `agent-tracker open-at-crash [--json]` |
| Reads | its own files, `~/.claude/sessions/<pid>.json` (live), the end of transcripts, `ps`, `tmux list-panes`, `sysctl kern.boottime` |
| Writes | `~/opt/agent-tracker/data/<uuid>/last_seen.json` (rewritten every 10 s) · `~/opt/agent-tracker/data/<uuid>/ended` (empty, once) |
| Triggered by | the statusline tick (every 10 s + each message) and one hook, SessionEnd. No daemon, no timer |
| Acts | no; ~400 bytes rewritten per tick, one empty file per ended Claude session |
| Consumed by | asm, notify, agent-usage-tracker's quota job, cc-map / cc-rc, terminal_snapshot |

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

**Choice:** agent-tracker writes only "where it runs" and "ended". Readers get everything else from its source: activity from the transcript, busy/idle from Claude Code's live file. Serves the goal in `AGENTS.md` ("no overlap").

**Why:** "which Claude session is in which pane" is kept in 4 places today and 2 vanish in a crash; nothing keeps "last seen" per Claude session; the transcript already holds every prompt and answer with its time, so copying it would be a fifth overlap.

**Rejected:** keep each project's own tracking (§0: 13 streams, 4 "alive?" rules); an `activity.jsonl` written at every hook (§3: duplicates the transcript).

## 2. Copy only with a reason

| Fact | Claude Code's live file | Transcript | After a crash | agent-tracker keeps it? |
|---|---|---|---|---|
| UUID, pid, folder, tmux pane | yes | folder only | pane, pid gone | yes, `last_seen.json` |
| last seen (while idle too) | updatedAt only on busy↔idle | no | gone | yes, `last_seen.json` ts |
| ended normally | file deleted | no exit entry | can't tell from a crash | yes, `ended` |
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
~/opt/agent-tracker/data/<uuid>/
  last_seen.json   written by `agent-tracker tick` every 10 s + each message; rewritten whole (temp file + rename)
                   {"ts":1794051573,"dt":"2026-11-07T11:39:33Z","agent":"claude","machine":"chan-lescut-macbook-pro",
                    "boot_ts":1794046382,"pid":4607,"pid_start":1794047610,"tmux_session":"jeanlescut",
                    "window_id":"@0","pane_id":"%0","pane":"jeanlescut:0.0","cwd":"/Users/jeanlescut",
                    "transcript":"~/.claude/projects/-Users-jeanlescut/cbf1952e-….jsonl"}
  ended            written once by `agent-tracker end` (SessionEnd hook): empty; its mtime = when the Claude session ended
```

| Who writes at the same time | Same file? | Why it is safe |
|---|---|---|
| two Claude sessions | no | one folder each |
| two ticks of one Claude session | yes, `last_seen.json` | temp file + `rename`: a reader sees the old or the new file, never half; the last one wins, which is the right answer |
| the SessionEnd hook | no | writes only `ended`, once |
| a power cut mid-write | — | rename is all-or-nothing: the old `last_seen.json` stays |

The user's layout (2026-11-07): `last_seen.json` kept as named; `index.json` / `activity.jsonl` dropped (the transcript has it); `usage.jsonl` waits for the scope (§8).

## 5. Reading, and lookups

```text
agent-tracker now   (cc-map, cc-rc, notify, terminal_snapshot, the user)
  for each data/<uuid>/ of the current boot, without "ended":
    alive?       pid running AND its start time == pid_start         # a reused PID does not count
    where?       pane_id -> its place now (tmux list-panes)
    busy/idle?   ~/.claude/sessions/<pid>.json (live)
    last prompt  the end of the transcript (<= 256 KB): last "user" entry

agent-tracker open-at-crash   (the user, the restore, once after a crash)
  prev_boot = the newest boot_ts that is not the current one
  last_tick = the newest ts among prev_boot's folders                 # ~ the moment of the crash
  each folder of prev_boot without "ended", with ts >= last_tick - 60 s   # killed ones stopped ticking earlier
  one per pane_id: the newest ts wins                                  # the pane was reused
```

Every hook and the statusline receive the UUID from Claude Code on stdin, so they open `data/<uuid>/` directly. Readers that start from a tmux pane use `now --pane <%id>`, which reads the current boot's folders (~30) [assumed cheap; measure in step 2]. No index by pane or PID: one more copy to keep in sync.

| Reader | Starts from | Today | New |
|---|---|---|---|
| asm resume | text, folder or UUID | scans `indexes/*.json` (up to 30 min old) | refreshes changed entries, then scans |
| asm close | a picked Claude session | `~/.claude/sessions/*.json` → pid | unchanged (live) |
| asm duplicate check | UUID | `lifecycles/<uuid>.jsonl` → old pids | `data/<uuid>/last_seen.json` → pid alive? |
| notify hooks | shell PID | `/tmp/agent-notify-$USER/<shell_pid>/` | UUID (hook) → `data/<uuid>/last_seen.json` → pane |
| cc-map, cc-rc | tmux pane | pane → process tree → `~/.claude/sessions/<pid>.json` | `now --pane` |
| terminal_snapshot | tmux pane | pane → process tree → `~/.claude/sessions/<pid>.json` | `now` |
| usage quota job | agent type | `heartbeat/claude` age | newest ts among `data/*/last_seen.json` |
| usage payload, Chrome kit | UUID | their own stores | unchanged |

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

## 7. What each project deletes, and keeps; the crash restore

| Project | Deletes | Keeps |
|---|---|---|
| asm | its SessionStart/SessionEnd hooks and `data/lifecycles/`; `session_state` (→ `ended`); maybe its 1800 s job (→ refresh at search time) | search, index of conversations, VM sync, resume, close |
| notify | its `/tmp` copy of shell PID, agent PID, pane, UUID, cwd | its states and colors, its own hooks |
| statusline | the per-agent heartbeat (→ newest `last_seen.json` ts) | the display, with no tracking code |
| usage-tracker | reading the heartbeat | everything else |
| my-setup | cc-map/cc-rc's process-tree walk; one of the two crash restores | the Chrome kit; the `statusLine` chain (§6) |

Two crash restores exist: `tools/terminal_snapshot.py` (2026-11-01: tmux + iTerm2 tabs + `claude --resume <id>`, by hand) and resurrect + continuum (2026-11-07: tmux only, Claude panes empty, 2 saves in 30 min instead of 6). **Proposal (the user decides):** keep terminal_snapshot, run it from `tick` at most every 5 min, feed it `agent-tracker now`, and remove resurrect + continuum.

## 8. Scope: what agent-tracker owns, and what may stay apart (open, the user, 2026-11-07)

| Data | In agent-tracker? | If it stays apart | For joining | For staying apart |
|---|---|---|---|---|
| where it runs, ended, last seen | yes, the core | — | copied 4 times today | — |
| asm's search index (title, text) | open | asm, refreshed at search time | one place for everything about a Claude session | about the conversation's content; synced to the VM; rebuilt from transcripts |
| tokens, cost, quotas | open | agent-usage-tracker, as today | its per-session part would sit with the rest | a different question (cost); its own triggers (OTel, polls); 80k+ rows in SQLite |
| pane colors | no | notify | | display, not tracking |
| Chrome tabs | no | my-setup's Chrome kit | | tabs, not Claude sessions |

## 9. Steps

| # | Step | Touches | Done when |
|---|---|---|---|
| 1 | this design, reviewed; scope and restore decided | agent-tracker | the user says yes |
| 2 | `tick` + `end` + my-setup's chain, beside today's streams; nothing removed | agent-tracker, my-setup | a `data/<uuid>/` folder for every Claude session, for 2 days |
| 3 | `now`, `open-at-crash`; terminal_snapshot on top | agent-tracker, my-setup | a killed test tmux gets its Claude sessions back |
| 4 | asm: index refreshed at search time; lifecycle (and maybe the 1800 s job) removed | asm | `asm resume --state pending` gives the same list, with no lag |
| 5 | notify, cc-map/cc-rc, usage quota job read it; their copies removed | each repo | each one's tests pass |

## Acceptance

- After a crash, `agent-tracker open-at-crash` lists exactly the Claude sessions that were open, with their pane, and nothing from older boots.
- `now` agrees with `~/.claude/sessions/*.json` for every live Claude session (same pane, same status), and its last prompt matches the transcript.
- No fact of §2 is stored in two places.

## Open points

- Does Claude Code run the statusline while its pane is hidden (another tmux window)? Decides whether last seen means "open" or "on screen", and the 60 s rule of `open-at-crash`; test in step 2.
- Does the VM sync still need asm's 1800 s job?
- Codex: statusline interval and SessionEnd hook, not measured (no Codex session today).
- Why continuum saved 2 times in 30 min instead of 6: moot if it is removed.

## Superseded decisions

- 2026-11-07: `events/<uuid>.jsonl` written at 5 hooks → replaced by §3 (computed when asked): the transcript already has every prompt and answer with its time.
- 2026-11-07: `state/events/` + `state/seen/` by kind → replaced by one folder per Claude session (the user's layout).
- 2026-11-07: a `touch` inside agent-statusline's script → replaced by §6 (my-setup chains `tick` before the display).
