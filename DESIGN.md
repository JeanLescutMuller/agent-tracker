# Design — agent-tracker

One project, the only writer of "which Claude session runs where, when it started, its last prompt, when it was last seen, whether it ended". Every other project only reads it. Guiding principle: a Unix tool, one job, no overlap; nothing new is kept that Claude Code or tmux already keeps. Words: the `## Vocabulary` table of [`AGENTS.md`](AGENTS.md). Status: proposal, 2026-11-07, waiting for the user's review; nothing is built.

| | |
|---|---|
| Command | `agent-tracker now` (what runs where, now) · `agent-tracker open-at-crash` (what was open when the previous boot ended) · both with `--json` |
| Reads | its own files (below), `ps`, `tmux list-panes`, `sysctl kern.boottime` |
| Writes | one folder per Claude session, `~/opt/agent-tracker/data/<uuid>/`: `last_seen.json` (rewritten every 10 s) · `activity.jsonl` (append-only, one line per event) · `usage.jsonl` (open, §7) |
| Triggered by | Claude/Codex hooks (start, prompt, stop, waiting, end) and the statusline tick (every 10 s). No daemon, no scheduled job |
| Acts | no; append < 512 bytes per event, rewrite ~400 bytes per tick |
| Consumed by | asm, notify, agent-usage-tracker, cc-map / cc-rc, the crash restore |

## 0. What exists today (measured 2026-11-07, 11:31–12:21, one boot)

Sources: a read-only inventory of the repos (file:line in [`design.html`](design.html)), `launchctl`, the plists in `~/Library/LaunchAgents/`, a 60 s sample of file writes every 0.25 s (12:05), and file ages at 12:20. Login was 11:31, so "runs since login" covers 50 min.

| # | Project · mechanism | Trigger | Interval, theory | In practice | Writes | Survives a crash | Read by | Lag of what readers see |
|---|---|---|---|---|---|---|---|---|
| 1 | asm · lifecycle | hooks SessionStart, SessionEnd | per event | 0 writes in the 60 s sample | `~/opt/agent-session-manager/data/lifecycles/<uuid>.jsonl` (436 files) | yes | asm index, asm's duplicate check | none; but a crashed session stays "pending" for ever (47 such files at the 11:12 crash) |
| 2 | asm · index | SessionEnd + scheduled | 1800 s | 2 runs in 50 min (expected 1.7 + 1 at login) | `data/indexes/<uuid>.json` | yes | `asm resume` | last_active of a live session: 1085 s behind its transcript (18 s) at 12:20 |
| 3 | asm · `close` | computed at read time | when typed | | nothing | | `asm close` | none |
| 4 | notify · per-shell state | hooks SessionStart, UserPromptSubmit, PreToolUse, Stop, Notification, SessionEnd; tmux select-pane; refresh piggybacked on any call | per event; refresh ≤ every 300 s | state.env 83 s and 114 s old at 12:20 | `/tmp/agent-notify-$USER/<shell_pid>/{static,state}.env` | **no** (/tmp) | notify's renderers (pane colors), cc-map | none for state; no timestamps kept |
| 5 | statusline · heartbeat | statusline tick | 10 s (`refreshInterval: 10`) + on each message | 10 writes in 60 s, gaps 0.8–10.1 s | `~/opt/agent-statusline/state/heartbeat/{claude,codex}`: **one time per agent, not per Claude session** | yes | agent-usage-tracker's quota polls only (age < 90 s) | ≤ 10 s; codex file 11.6 days old |
| 6 | usage-tracker · statusline payload | statusline tick | 10 s | 26 writes in 60 s (state folder) | `data/claude/sessions_usages.db` (SQLite) | yes | its reports | ≤ 10 s |
| 7 | usage-tracker · OTel | pushed by Claude Code | every few seconds | receiver running since login | same db, table telemetry | yes | aggregates | seconds |
| 8 | usage-tracker · transcripts | scheduled | 300 s | 10 runs in 50 min (expected 10) | `data/claude/intermediary.db` | yes | 5-min slots | ≤ 300 s |
| 9 | usage-tracker · quota polls | scheduled | 60 s (claude, codex) | 46 runs in 50 min (expected 50) | quota files | yes | statusline | 110–480 s, by design |
| 10 | my-setup · Chrome kit hook | hooks PreToolUse (Chrome, Bash), PostToolUse, UserPromptSubmit, Stop, SubagentStop | per event | 2 writes in 60 s | `~/opt/my-setup/state/chrome/` | yes | the hook, agent-chrome | none; tabs only, no liveness |
| 11 | my-setup · cc-map, cc-rc | computed at read time from `~/.claude/sessions/*.json`, tmux, notify | when typed | | nothing | | skill claude-sessions-overview | none |
| 12 | my-setup · `tools/terminal_snapshot.py` | by hand (no caller found) | — | last run 2026-11-01 17:21 | `~/.local/state/terminal-snapshot/*_restore.sh` | yes | the user, after a reboot | 6 days |
| 13 | my-setup · resurrect + continuum (added 2026-11-07) | tmux status redraw | 300 s | **2 saves in 30 min** (11:58:37, 12:18:37; expected 6); cause not found | `~/opt/my-setup/state/tmux/resurrect/` | yes | prefix + Ctrl-r | 20 min measured |
| — | Claude Code itself · `~/.claude/sessions/<pid>.json` | Claude Code, on each busy/idle change | per change | 0 writes in 60 s while busy; file 252 s old | pid, sessionId, cwd, tmux `s:@w.%p`, status, updatedAt | **no**: removed or pid dead after a crash | asm close, cc-map, cc-rc, terminal_snapshot | none while it runs |

The same fact kept in several places (the overlap the user asked to remove):

| Fact | Kept by |
|---|---|
| Claude session ↔ tmux pane | asm lifecycle (indexes `#S #I #P`), notify (`%pane`, `@window`), Claude Code (`tmux`), Chrome kit (`#S:#I`), terminal_snapshot, resurrect (none: only "claude") |
| PID | asm lifecycle, notify (shell and agent), Claude Code |
| start / end | asm lifecycle, notify (file created / deleted), Claude Code (file present / absent) |
| busy / idle | notify (hooks), Claude Code `status` |
| last activity | asm index (transcript, ≤ 30 min late), Claude Code `updatedAt`, usage-tracker (requests, telemetry), statusline (per agent only) |
| alive? (`kill -0`) | asm (twice), notify, cc-map, cc-rc |
| last prompt | **nobody** |
| last seen per Claude session | **nobody** (the heartbeat is per agent) |

## 1. One writer, every other project a reader

**Choice:** agent-tracker is the only project that records Claude session facts; asm, notify, usage-tracker, cc-map and the crash restore read them through `agent-tracker now|open-at-crash --json`, never by keeping their own copy. Each keeps its own job: asm finds and resumes, notify colors panes, usage-tracker counts tokens.

**Why:** 13 mechanisms record overlapping facts today (§0); 4 of them decide "alive" each in their own way, so they can disagree, and none answers "last prompt" or "last seen per Claude session".

**Rejected:** keep each project's own tracking (today) — the overlap above, and every new need (the crash restore) adds one more copy. Put the tracker inside asm — asm's job is finding and resuming past Claude sessions across machines; mixing live state into it is what made its index say "pending" for crashed sessions.

## 2. What triggers a write

**Choice:** hooks for events, the statusline tick for "last seen". Nothing runs on a timer.

| Trigger | Fires | Writes | Rate per Claude session [verified unless marked] |
|---|---|---|---|
| hook SessionStart | start, resume, `/clear` | event `start` | 1 per start |
| hook UserPromptSubmit | the user sends a message | event `prompt` (with `chars` and a ~200-character `excerpt`) | this session: 15 in 45 min, ≈ 1 every 3 min |
| hook Stop | Claude finishes its turn | event `stop` | ≈ same as prompts |
| hook Notification (idle, permission) | Claude waits for the user | event `waiting` | a few per hour [assumed] |
| hook SessionEnd | `/exit`, Ctrl-D, closed terminal | event `end` | ≤ 1; **never on a crash** |
| statusline tick | every 10 s, and on each message | `agent-tracker tick` (chained before the display) rewrites `last_seen.json` | ≤ 6 per minute, measured gaps 0.8–10.1 s |

Codex: the same events through its plugin hooks (asm and notify already use them: `src/codex-plugin/hooks/hooks.json`, `release/codex/hooks/hooks.json`) and the patched Codex statusline.

**Why:** an event is written when it happens (no lag), and only then (no work while nothing happens). A crash sends no `end`, which is exactly why "last seen" and `boot_ts` exist (§4).

**Rejected:**

| Option | Why it lost |
|---|---|
| A. no writer, computed at read time from `~/.claude/sessions/*.json` | those files vanish or go stale with a crash; no history, no last prompt, no Codex |
| C. a daemon polling `ps` + tmux every N s | a process always running; up to N s late; misses short Claude sessions; still needs a hook for the prompt time |
| D. one SQLite file written by every hook | every hook of every Claude session takes the same lock (10+ sessions × each prompt and tick); a hook must be fast and never fail; SQLite stays possible later as a read cache |
| PreToolUse hook | fires on every tool call (dozens per minute when busy); nothing the user asked for needs it; notify keeps its own if it needs it (§6) |

## 3. Files, and why there are no write collisions

**Choice:** one folder per Claude session, one file per writer (the user's layout, 2026-11-07, with two renames). Every project writes only its own file, through an `agent-tracker` command, so the folder's format has one owner.

```text
~/opt/agent-tracker/data/<uuid>/
  last_seen.json   written by `agent-tracker tick`, chained before the statusline by my-setup, every 10 s; rewritten whole (temp file + rename)
                   {"ts":1794051573,"dt":"2026-11-07T11:39:33Z","boot_ts":1794046382,"pid":4607,"pid_start":1794047610,
                    "tmux_session":"jeanlescut","window_id":"@0","pane_id":"%0","pane":"jeanlescut:0.0",
                    "cwd":"/Users/jeanlescut"}
  activity.jsonl   written by agent-tracker's hook script; append-only, one line per event, each < 512 bytes
                   {"ts":1794047617,"dt":"2026-11-07T10:33:37Z","event":"start","source":"startup","agent":"claude",
                    "machine":"chan-lescut-macbook-pro","boot_ts":1794046382,"pid":4607,"pid_start":1794047610,
                    "shell_pid":4328,"tmux_session":"jeanlescut","window_id":"@0","pane_id":"%0","cwd":"/Users/jeanlescut"}
                   {"ts":1794047617,"dt":"2026-11-07T10:33:37Z","event":"prompt","chars":312,"excerpt":"I went to bed and…"}
                   {"ts":1794047702,"dt":"2026-11-07T10:35:02Z","event":"stop"}
  usage.jsonl      (open, §7) written by agent-usage-tracker: cost and quota data the transcript does not have
```

| The user's suggestion | Here | Why |
|---|---|---|
| `last_seen.json`, by the statusline, with tmux info | kept | the pane and folder stay fresh, so a crash loses ≤ 10 s; better than an empty "seen" file |
| `index.json` (to rename): prompts and answers with their times | `activity.jsonl` | append-only lines never collide and survive a power cut; a JSON rewritten at each event could be cut in half; the full text stays in the transcript |
| `extra_usage_infos.jsonl` | `usage.jsonl` | shorter; whether usage-tracker writes here or keeps its database is open (§7) |
| `~/opt/agent-tracker/data/<uuid>/` | kept | all files of one Claude session together; archive or delete = one folder |

| Who writes at the same time | Same file? | Why it is safe |
|---|---|---|
| two Claude sessions | no | one folder each |
| two hooks of one Claude session (e.g. subagents) | yes, `activity.jsonl` | each event is one append of < 512 bytes with `O_APPEND` (`>>`): appended whole, lines never mixed [assumed, to test on APFS in step 2] |
| statusline ticks | yes, `last_seen.json` | temp file + `rename`: a reader sees the old or the new file, never half; the last one wins, which is the right answer |
| a reader during a write · a power cut mid-write | — | a line of `activity.jsonl` without its final newline is ignored; `last_seen.json` is never half-written |

Today's shared heartbeat file (one per agent, written by every Claude session) is the only real collision: last writer wins, so it cannot say which Claude session is open. `last_seen.json` replaces it; the per-agent time is the newest `ts` among them.

## 3b. Copy only with a reason; how readers look things up; who owns the statusline call

**Copy rule:** while a Claude session runs, read Claude Code's own `~/.claude/sessions/<pid>.json` (pid, UUID, cwd, tmux pane, status, updatedAt, name, bridgeSessionId). agent-tracker copies a fact only if a crash loses it or Claude Code never keeps it. [verified 2026-11-07 12:48: the 28 files there were all created after 11:31; none from before the 11:12 crash survived.]

| Fact | Claude Code's file | After a crash | agent-tracker keeps it? |
|---|---|---|---|
| UUID, pid, cwd, tmux pane | yes | gone | yes, `last_seen.json` (the crash restore needs them) |
| status, updatedAt, name, Remote Control | yes | gone | no: read live |
| last prompt; start / end / resume history; boot | no | — | yes, `activity.jsonl` |
| last seen | updatedAt only on busy↔idle | gone | yes, `last_seen.json` ts |
| anything Codex | no such file | — | yes |

**Lookups:** every hook and the statusline receive the UUID from Claude Code on stdin, so most readers open `data/<uuid>/` directly. Readers that start from a tmux pane (cc-map, cc-rc, terminal_snapshot) use `agent-tracker now --pane <%id>`, which reads the `last_seen.json` of the current boot's folders (~30) [assumed cheap; measure in step 2]. No index file by pane or PID is kept: it would be a second copy to keep in sync.

| Reader | Starts from | Today | New |
|---|---|---|---|
| asm resume | text, folder or UUID | scans `indexes/*.json` | same for text; state and last prompt from `data/<uuid>/` |
| asm close | a picked Claude session | `~/.claude/sessions/*.json` → pid | unchanged (live) |
| asm duplicate check | UUID | `lifecycles/<uuid>.jsonl` | `data/<uuid>/activity.jsonl` |
| notify hooks | shell PID | `/tmp/agent-notify-$USER/<shell_pid>/` | UUID from hook stdin → `data/<uuid>/last_seen.json` |
| cc-map, cc-rc | tmux pane | pane → process tree → `~/.claude/sessions/<pid>.json` | unchanged for live data; `now --pane` for last prompt |
| terminal_snapshot | tmux pane | pane → process tree → `~/.claude/sessions/<pid>.json` | `agent-tracker now` / `open-at-crash` |
| usage quota job | agent type | `heartbeat/claude` age | newest `ts` among `data/*/last_seen.json` |

**Who owns the statusline call:** Claude Code runs one `statusLine` command; that key is owned by my-setup (`modules/claude_config.sh`, skill config-ownership) and points to agent-statusline's script. **Choice:** my-setup chains `agent-tracker tick | bash ~/.claude/statusline-command.sh` when agent-tracker is installed, the display alone otherwise. `tick` reads the JSON from stdin, writes `last_seen.json` in the background, and copies stdin to stdout unchanged. **Why:** agent-statusline holds no tracking code, so reinstalling it on a VM, or rewriting the display, cannot drop the tracking. **Rejected:** a line inside agent-statusline's script (a display rewrite can drop it silently); agent-tracker owning `statusLine` (two projects fighting over one key, last install wins).

| New VM gets | Display | Tracking |
|---|---|---|
| my-setup + agent-statusline | yes | no, nothing breaks |
| + agent-tracker | yes | yes: my-setup chains both |
| agent-statusline reinstalled later | yes | yes: the chain lives in my-setup's setting |

## 4. Reading: computed at read time, never stored twice

**Choice:** `now` and `open-at-crash` are computed from the files when asked.

```text
now:
  for each data/<uuid>/ whose activity.jsonl's last event is not "end":
    alive = pid running AND its start time == pid_start      # a reused PID does not count
    if alive: row(uuid, tmux pane %id -> current "<session>:<window>.<pane>", cwd, status, last prompt, last seen (last_seen.json ts))

open-at-crash:
  prev_boot = the boot_ts before the current kern.boottime (from the events themselves)
  for each Claude session with events in prev_boot:
    skip if its last event is "end"
    skip if a later "start" in prev_boot took the same pane_id    # the pane was reused
    row(uuid, pane, cwd, last prompt, last seen)
```

Worked example (the 2026-11-07 crash, from asm's lifecycle files): 47 Claude sessions "never ended" since 2026-10; with `boot_ts`, only those started after the previous boot count, and two starts in `job-applications:0.0` keep only the later one.

| Reader | Reads | How often | Cost per read |
|---|---|---|---|
| notify (pane colors) | the one Claude session of its pane | on each of its hooks | 1 small file |
| usage-tracker quota polls | the newest `ts` among `*/last_seen.json` | 60 s | one small file per Claude session of the current boot |
| asm resume, cc-map, cc-rc | `now` | when typed | the files of the current boot: ~10–50 files < 10 KB each [assumed] |
| the crash restore | `open-at-crash` | once after a crash | same |

Old folders: a `<uuid>/` whose newest file is older than 30 days moves to `data/old/` (read only by `--all`) [proposal].

## 5. What each project deletes, and keeps

| Project | Deletes | Keeps |
|---|---|---|
| asm | its SessionStart/SessionEnd hooks and `data/lifecycles/`; `session_state` and `last_active` come from the tracker | search, index of conversations, sync across machines, resume, close |
| notify | its own bookkeeping of shell PID, agent PID, pane, Claude session, cwd (static.env) | its state machine and colors; its hooks only where a color must change at once (it may call the tracker's file instead of `ps`) |
| statusline | the per-agent heartbeat (derived from `*/last_seen.json`) | the display; no tracking code: my-setup's `statusLine` setting chains `agent-tracker tick | bash statusline-command.sh` (§3b) |
| usage-tracker | reading the heartbeat file | everything else (tokens, quotas) |
| my-setup | cc-map/cc-rc reading `~/.claude/sessions` and notify; one of the two crash restores (§6) | the Chrome kit (it tracks tabs, not Claude sessions) |

## 6. The crash restore: one tool, not two

Today there are two: `tools/terminal_snapshot.py` (2026-11-01: tmux + iTerm2 tabs + `claude --resume <id>` per pane, run by hand) and resurrect + continuum (2026-11-07: tmux only, a Claude pane comes back as an empty shell, and it saved 2 times in 30 min instead of 6).

**Choice (proposal, the user decides):** keep `terminal_snapshot.py`, feed it `agent-tracker open-at-crash` instead of `~/.claude/sessions`, run it from a tracker event (`start`, `end`) instead of by hand, and remove resurrect + continuum.

**Why:** it already restores iTerm2 windows and Claude sessions, which resurrect cannot; written on events, it is never 20 min late.

**Rejected:** resurrect for the layout + a script for Claude — two tools for one restore, and continuum's measured saves are unreliable.

## 7. Scope: what agent-tracker owns, and what may stay apart (open, the user, 2026-11-07)

| Data | In agent-tracker? | If it stays apart | For joining | For staying apart |
|---|---|---|---|---|
| session facts: pane, start, end, last prompt, last seen | yes, the core | — | copied 4 times today | — |
| asm's search index (title, text) | open | asm, reading the facts from agent-tracker | one place for everything about a Claude session | about the conversation's content; synced to the VM; rebuilt from transcripts |
| tokens, cost, quotas (`usage.jsonl`) | open | agent-usage-tracker's SQLite, as today | the per-session part sits with the rest | a different question (cost); its own triggers (OTel, polls); aggregates 80k+ rows |
| pane colors | no | notify | | display, not tracking |
| Chrome tabs | no | my-setup's Chrome kit | | tabs, not Claude sessions |

Whatever is decided, the session facts have one writer; everything else reads them.

## 8. Steps

| # | Step | Touches | Done when |
|---|---|---|---|
| 1 | this design, reviewed by the user | agent-tracker | the user says yes |
| 2 | build the writer (hooks + statusline line) beside today's mechanisms, nothing removed | agent-tracker, statusline (1 line) | a `data/<uuid>/` folder with `last_seen.json` and `activity.jsonl` for every Claude session, for 2 days |
| 3 | `now` and `open-at-crash`; the crash restore on top (§6) | agent-tracker, my-setup | a test tmux killed and restored gets its Claude sessions back |
| 4 | asm reads the tracker; its hooks and lifecycles removed | asm | `asm resume --state pending` gives the same list |
| 5 | notify, then cc-map/cc-rc, then usage-tracker read it; their copies removed | each repo | each one's tests pass |

## Acceptance

- After a crash, `agent-tracker open-at-crash` lists exactly the Claude sessions that were open, with their pane, and nothing from older boots.
- `now` agrees with `~/.claude/sessions/*.json` for every live Claude session (same pane, same status).
- Each removal in §5 leaves no second copy of a fact in §0's overlap table.

## Open points

- Continuum saved 2 times in 30 min instead of 6: not investigated (moot if §6 removes it).
- Whether notify needs PreToolUse at all once it reads the tracker (its "Working" after a permission prompt).
- Codex statusline tick interval: not measured (no Codex session today).
- The VM: same tracker there, per machine; asm's sync carries what crosses machines.
- Whether a single small append to a local file is ever split on APFS: to test before relying on it (step 2).
- Whether Claude Code keeps running the statusline when its pane is not on screen (another tmux window): decides whether `last_seen.json` means "open" or "on screen"; to test in step 2.
