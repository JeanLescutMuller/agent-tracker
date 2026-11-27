# For readers: how to read this project's data

For any project or script that **reads** what agent-tracker (agent-usage-tracker until 2026-11) stores: a status line, auto-job-apply, agent-resume, claude-close-keep-screen, agent-notify, an analysis. Sections 1–3: the usage databases; section 4: the session files and `quota_latest.json`. This file says how to read it safely, and what to read. What each field means: `doc/tables.md`; what exists upstream: `doc/upstream.md`; why it is built this way: `doc/design.md`; when a row's shape changed: `doc/changes.md`.

Last checked: 2026-11-27 (rule 20: `quota_rules.json`).

## 1. Rules

| # | Rule | Why |
|---|---|---|
| 1 | **Never write.** Only this project's gates write its databases, and only `agent-tracker` its session files and `quota_latest.json` | every row is insert-only and deduplicated by the gate |
| 2 | **Open read-only with `PRAGMA query_only = ON`**, never a `mode=ro` URI; set a busy timeout (10 s here) | macOS's SQLite intermittently refuses a `mode=ro` open of these WAL databases ("unable to open database file") |
| 3 | **Read only the new rows by `rowid`, never by `ts` or `written_ts`**: remember the largest `rowid` you read, then `WHERE rowid > ?`. A time range (not "what is new") filters on `ts`, indexed in every table | many rows are written well after their `ts` (section 2): a `ts` watermark silently skips them, forever |
| 4 | A `rowid` is local to one database file. **The same row has a different `rowid` on the Mac and on the central (the NAS; the VM until 2026-11)**; across machines a row is identified by `row_hash` | each machine inserts in its own order |
| 5 | **A quota percent is account-wide only.** Never attribute it to a session, a folder or a machine | the meter is one number for the account (`doc/tables.md` §1) |
| 6 | **The percent also counts usage no local file sees** (claude.ai chats, the mobile and desktop apps, Cowork, cloud sessions) | any correlation of the % with local tokens or $ assumes that share is small (`doc/upstream.md` §2.3) |
| 7 | **Every $ is Claude Code's own list-price figure** (tokens × list price), not a bill. Where it is missing, do not compute one; use the tokens | no server returns a usage $ (`doc/upstream.md` §1) |
| 8 | **A window whose reset time has passed is at 0%**, whatever the last reading says, until a new reading arrives; `latest` already applies it | readings stop while nobody uses Claude Code (`doc/design.md` P15) |
| 9 | **A stretch with no reading at all is unknown, not unchanged** | while Claude Code runs on neither machine for more than 8 h, no reading is taken; usage elsewhere shows up afterwards as a total (`doc/design.md` P15) |
| 10 | **Within one window the percent never decreases**: in a series, keep the first reading of each new running maximum, keyed by `ts` | older statusline rows include stale re-sent readings (`doc/tables.md` §7.2) |
| 11 | **Never compare a percent across plans** (Pro until 2026-10-07 16:51 UTC, Max 5x since) | 1% of Max 5x weighs about 4× a Pro 1% (`adhoc_quotas_analysis/CONCLUSIONS.md` §2) |
| 12 | **Slots before 2026-11-24 count some requests twice**: skip a slot whose `folder` is under another machine's home (`usage_db.foreign_folder(folder, home)`, the machine's home being the one its slots with an account or a $ ran under: `src/dashboard.py`'s `machine_home`) | agent-resume syncs transcripts both ways and each machine counted the other's requests too, with no account and no $ (NAS 28,741 requests since 2026-10-13, Mac 930 since 2026-11-22; `doc/changes.md` 2026-11-24) |

## 2. Rows written after their `ts` (rule 3)

| Rows | Written after their `ts` by | Since |
|---|---|---|
| `claude_statusline` readings | up to the session's idle time: `ts` is the session's last API response, written at its next render | 2026-09-30 |
| Every reading from the other machine (sync every 2 min) | up to about 2 min; it keeps the other machine's `written_ts` | 2026-10-10 |
| `slots` | 15 min or more after the slot ends; the Mac's slots reach the central up to 5 min later, or hours later after the Mac slept | 2026-10-10 |

Example: a reader runs at 10:00:00 and remembers `ts` 09:59:50. At 10:01 the sync brings the central's reading of 09:59:30: `ts > 09:59:50` misses it forever; `rowid > 4812` finds it.

```python
db = sqlite3.connect(path, timeout=10, isolation_level=None)
db.execute("PRAGMA busy_timeout = 10000")
db.execute("PRAGMA query_only = ON")
l_rows = db.execute("SELECT rowid, * FROM account_quotas WHERE rowid > ? ORDER BY rowid", (last_rowid,)).fetchall()
last_rowid = l_rows[-1][0] if l_rows else last_rowid   # keep it in your own state
```

## 3. What to read

All paths under `~/opt/agent-tracker/` (`$AGENT_TRACKER_HOME`; `~/opt/agent-usage-tracker/` until the rename, `doc/deploy_migration.md`). Claude only; Codex: `doc/tables.md` §6.

| Question | Read |
|---|---|
| The account's quota now | view `latest` of `data/claude/account_quotas.db`: the freshest reading, any source, any machine, the reset rule applied (a passed window reads 0%, its reset NULL). The status line reads `data/claude/quota_latest.json` instead (section 4); until the switch it got six `\x1c`-separated fields printed by `src/statusline_payload_reader.py` (`doc/tables.md` §3.3) |
| Quota history | table `account_quotas` of the same database: **the same rows on both machines**; `machine` = the machine that took the reading (NULL for 72 readings copied between the machines on 2026-10-10 before the sync existed) |
| Tokens and $ per 5-min slot, folder, interactive or not | table `slots` of `data/claude/aggregates/<machine>.db` (one file per machine): 5-min slot × machine × folder × entrypoint × job × model; 6 token columns, `usd` (Claude Code's own), `tokens_without_usd` (the part `usd` does not cover) |
| The same, every machine at once | on the central (the NAS): every file in `data/claude/aggregates/` (`BabisNAS.db`, the NAS's; `H-Frank-1.db`, the VM's until 2026-11; `chan-lescut-macbook-pro.db`, the Mac's); `UNION ALL` their `slots` |
| Per request, per session | `telemetry` (one row per API request event, Claude Code's own cost; count requests through the view `telemetry_requests`) and `session_snapshots` in `data/claude/sessions_usages.db`, each machine its own (Category 2, never shared). The per-request transcript rows in `data/claude/intermediary.db` are local working tables, deletable: **not for readers** |
| "Interactive or scheduled" | `slots.job` (since 2026-11-20): the job-runner job's name for a scheduled job's sessions; `''` for everything else (an interactive session, its subagents and the `claude -p` it ran: split those by `folder`). `slots.entrypoint` says how Claude was started: `cli` = interactive terminal, `sdk-cli` = `claude -p`, `sdk-py` = Agent SDK; a `claude -p` an interactive session ran is `sdk-cli` with `job` `''`. E.g. `SELECT CASE WHEN job <> '' THEN 'job ' \|\| job ELSE 'interactive ' \|\| folder END, ROUND(SUM(usd), 2) FROM slots WHERE ts >= strftime('%s', 'now', '-7 days') GROUP BY 1` |
| Tokens and $ per Claude account | `slots.account` (since 2026-11-21): the account's organization uuid (`accounts.org_uuid` of `account_quotas.db` names it, for the machine that wrote the slot); `''` for every slot written before that date and for a request no telemetry event named. The older rows are not rewritten: for a total per account over a longer past, sum `sessions_usages.db` `telemetry.account` (since 2026-11-19) |
| Something you read before 2026-10-10 (`state/quota/claude`, the views `usage_5m` / `usage_requests`, `central/`) | gone: `doc/changes.md` says what replaced it |

The four categories (`doc/design.md` §1): **1** quotas, raw, shared by both machines; **2** each machine's raw rows, never shared; **3** `slots`, aggregates of 2, the Mac's sent to the central; **4** anything computed from 1 + 3 belongs to the reader, not to this project.

## 4. The session files and `quota_latest.json` (since 2026-11-07)

Written only by `agent-tracker` (`src/agent_tracker.py`; why: `doc/design.md` §14). Every write of a whole file is a temp file + rename: a reader sees the old or the new file, never half.

| File | Written by, when | One line or file = |
|---|---|---|
| `data/sessions/<uuid>/last_seen.json` | `agent-tracker tick` (the statusline, every 10 s + each message), rewritten only when a field other than `ts`/`dt` changed, or once a minute | where the Claude session runs now: the file below |
| `data/sessions/<uuid>/lifecycle.jsonl` | `agent-tracker hook start\|end` (SessionStart, SessionEnd), one appended line < 512 bytes; never for `claude -p` or an SDK process (the Remote Control bridge) since 2026-11-07 | one start (startup, resume, clear, compact) or one end |
| `data/claude/quota_latest.<name>.json` (one per Claude account: `a`, `b`...; since 2026-11-22 the only Claude files: `quota_latest.json` is gone) | `tick` (statusline readings) and `claude_quota_api_poller.py` (after each run: its own reading or one the sync brought), only when fresher (larger `ts`, or the same `ts` with other values) | that account's freshest reading: `ts`, `dt`, `source`, `machine`, `five_hour`, `seven_day`, plus `"account_name"` and `"account"` (its organization uuid; absent while the machine does not know it) |
| `data/claude/quota_rules.json` (since 2026-11-27) | `src/quota_rules.py`, the job agent-tracker.quota-rules (hourly, each machine for itself), only when its content changed (or once a day) | per account: `plan` (its login's rate-limit tier), `account_factor`, `five_hour_windows_per_week` (measured, pooled per plan), `points_per_5h_pct`, `points_per_7d_pct`, `weekly_reset` (fixed weekday and UTC time, the next one), `billing` (the monthly day, from `~/.config/agent-tracker/billing.json`, or null); `unit`: a point = one full 5-hour window of the reference account (a) |
| `data/codex/quota_latest.json` | `codex_quota_api_poller.py`, after each run, when fresher | the same, for Codex |
| `data/snapshots/<boot_ts>.tsv` (since 2026-11-17) | `src/terminal_snapshot.sh`, started in the background by `tick` at most once a minute (so only while a Claude session runs); rewritten whole only when its content changed | the terminal layout of that boot: one row per tmux pane, tmux client and iTerm2 tab |

```text
last_seen.json   {"ts":1794051573,"dt":"2026-11-07T11:39:33Z","agent":"claude","machine":"chan-lescut-macbook-pro","boot_ts":1794046382,
                  "uuid":"cbf1952e-…","pid":4607,"pid_start":1794047610,"tmux_session":"jeanlescut","window_id":"@0","window_index":0,
                  "window_name":"zsh","pane_id":"%0","pane_index":0,"pane":"jeanlescut:0.0",
                  "window_layout":"b25f,208x52,0,0{104x52,0,0,1,103x52,105,0,2}","cwd":"/Users/jeanlescut",
                  "transcript":"/Users/jeanlescut/.claude/projects/-Users-jeanlescut/cbf1952e-….jsonl"}
lifecycle.jsonl  {"ts":…,"dt":"…","event":"start","source":"startup","agent":"claude","machine":"…","boot_ts":…,"pid":4607,"pid_start":…,
                  "pane_id":"%0","pane":"jeanlescut:0.0","cwd":"/Users/jeanlescut"}
                 {"ts":…,"dt":"…","event":"end","reason":"exit","pid":4607}
quota_latest     {"ts":1794051573,"dt":"…","source":"statusline","machine":"chan-lescut-macbook-pro",
                  "five_hour":{"used_percentage":55,"resets_at":1788091200},"seven_day":{"used_percentage":70,"resets_at":1788307200}}
snapshots/<boot_ts>.tsv   tab-separated, no header; ts and dt first (when that part was read: the iterm rows may be older)
                 ts  dt  pane    <tmux session> <window index> <pane index> <pane_id> <command> <pane folder> <window_layout> <window name>
                 ts  dt  client  <tty> <tmux session>
                 ts  dt  iterm   <window position, 1 = front> <window id> <tab position> <tty> <bounds x1,y1,x2,y2>
```

| # | Rule | Why |
|---|---|---|
| 12 | `tmux_*`, `pane*`, `window_*` are `null` outside tmux; `pid` / `pid_start` `null` when no agent process was found | a Claude session run outside tmux, or by a script |
| 12b | A Codex start/end line with `pid`, `pane_id`, `pane` all `null`: its hook ran in Codex's shared background process (`codex app-server`, Codex ≥ 0.167), which is not the window; the window's pid and pane are in `last_seen.json`, written by its status line (`tick --agent codex`, my-setup's `codex-statusline-chain`). `now` takes them from there | one background process serves every Codex window and keeps the pane the first one was opened in (2026-11-07) |
| 13 | **Alive = `pid` runs and its start time equals `pid_start`** (±1 s); a pid alone may have been reused | macOS and Linux reuse pids |
| 14 | **Ignore a `lifecycle.jsonl` line without its final newline** (being written); a crash leaves a start with no end: a Claude session is open only if its last event is a start in the current boot (`boot_ts`) and its pid is alive | there is no exit entry anywhere else |
| 15 | A pane is named by `pane_id` (`%id`), stable while tmux runs; `pane` (`session:window.pane`) was true when written: resolve `pane_id` through tmux for the place now (`agent-tracker now` does) | windows are renamed, moved |
| 16 | `quota_latest.json`: apply rule 8 (a window whose `resets_at` has passed is at 0%); a window may be `null`; `ts` is when the reading was true (the statusline's: the session's last API response) | the file is the reading, not a view |
| 17 | `last_seen.json`'s `ts` is at most ~70 s old while its statusline runs (10 s ticks, a rewrite at least once a minute): "on screen" = younger than 90 s; older than 2 min = not ticking | `check` and the quota jobs use these thresholds |
| 18 | Snapshot: an iTerm2 tab shows the tmux session whose `client` row has the same tty; a pane's Claude session is the one whose `last_seen.json` (or start line) of that boot has the same `pane_id`, when the pane's `<command>` (its foreground command) was not a shell: Claude Code shows as its version (`2.1.326`). The `pane` rows are at most ~1 min old while a Claude session ran; the `iterm` rows up to 10 min for a dragged tab (opened or closed tabs: ~1 min). The window name is last: it may hold a tab | iTerm2 knows ttys, not tmux sessions; asking iTerm2 costs ≈ 70 ms of CPU |
| 19 | **Since 2026-11-22 no account is preferred.** `account_quotas.account` is the organization uuid (NULL before 2026-11-19, when there was one account: the account named a); `latest_by_account` has one row per account (`name` from the machine's `accounts` table, NULL if unknown); **`latest` is the reading of the account with the most room left** (room = 100 - max(5h %, 7d %), a reading younger than 15 min first, a tie: the first name), the rule of my-setup's `claude` command; `data/claude/accounts.json` maps a config folder to `{name, org_uuid}`. A session's account: its `CLAUDE_ACCOUNT` (set by the wrapper), also in the `start` line of `lifecycle.jsonl` (`"account"`); a reader that has none takes the account with the most room. A reader that needs one account's quota reads `quota_latest.<name>.json` or `latest_by_account` | one machine, several claude.ai logins |
| 20 | **`quota_rules.json` turns a percent into points**: room in points = (100 − %) × `points_per_<meter>_pct`; an account whose `account_factor` is null has another plan than the reference: never compare it (rule 11). `five_hour_windows_per_week` is a median with a wide spread (p10–p90 about 2–13 on 2026-11-27): use it to rank, not to promise. `weekly_reset` is fixed per account (a: Mon 19:00 UTC, b: Wed 06:00 UTC on 2026-11-27); `billing` is a stated fact (its `source`), kept out of this public repo: null on a machine without the file | Computed from Category 1 and the logins, for every reader that compares accounts (my-setup's `claude` command); the user, 2026-11-27 |

`agent-tracker now --json` (the open Claude sessions of the current boot, computed when asked: nothing stored) prints a JSON array, one object per Claude session, with exactly these keys, in this order:

```text
{"uuid","agent","pid","pid_start","pane_id","pane","tmux_session","window_index","pane_index","cwd",
 "status",        busy / idle from Claude Code's live $CLAUDE_CONFIG_DIR/sessions/<pid>.json, null if absent
 "transcript",
 "last_prompt",   {"ts": epoch int, "dt": ISO UTC} of the transcript's last user entry that is not a tool result, or null
 "last_seen"}     {"ts","dt"} of last_seen.json, or null
```

`pane`, `tmux_session`, `window_index`, `pane_index` are resolved now from `pane_id` (`null` when tmux no longer has that pane). `--pane %id` and `--uuid U` keep one row. Readers: claude-close-keep-screen, the user. `agent-tracker check` says whether every writer is writing on this machine (exit 1 and one line per problem).

## 5. When this file changes

Any change to what a reader reads, or how, updates sections 3 and 4 here, its "Last checked" line, and adds a row to `doc/changes.md`.
