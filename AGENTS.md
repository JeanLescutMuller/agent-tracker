# agent-tracker

Design stage (2026-11-07): nothing is built yet. Role (the user, 2026-11-07): a foundational layer that makes sure the data about Claude sessions is recorded and present; no feature code. Its only feature is visibility (`now`, `check`); features (resume, crash restore, colors) live in the projects that read its files. It is agent-usage-tracker grown and renamed (the user, 2026-11-07); this folder is temporary and moves into that repo at step 1b. Read [`DESIGN.md`](DESIGN.md) first; the page for the user is [`design.html`](design.html) (same content, with colors and diagrams). Both must say the same thing: change them together.

Goal, in the user's words (2026-11-07): one project that knows "what is running exactly where, what was open, what was exited, for each session when was the last time I sent a prompt, when was the last time we detected the session being open on the laptop", so that asm, notify, the statusline and the crash restore stop each keeping their own copy ("a unix approach, with no overlap").

## Vocabulary

| Word | Means | Never say |
|---|---|---|
| Claude session | one conversation of Claude Code (or Codex), named by its UUID | "session" alone, when a tmux session could be meant |
| tmux session · window · pane | tmux's own words; a pane is named by tmux's `%id` (stable while tmux runs) and shown as `<tmux session>:<window>.<pane>` | |
| last prompt | time of the user's last message in a Claude session, read from the end of its transcript when asked | last active |
| last seen | last time the statusline ran for a Claude session (every 10 s while it is open): the `ts` of its `last_seen.json` | heartbeat (that word stays the statusline's own per-agent file) |
| boot | one run of the Mac, from power-on to shutdown or crash; named by its start time `boot_ts` | |
| open at crash | a Claude session whose last lifecycle event is a start in the previous boot, still ticking at the crash (computed by `asm resume-tmux`, not by agent-tracker) | |
| Claude session folder | `~/opt/agent-tracker/data/sessions/<uuid>/`: `last_seen.json` (where, by the statusline) and `lifecycle.jsonl` (start, resume, end, by hooks) | |
| on call | computed when a command runs, from its source, never stored (option 3); who runs each command and how often: `DESIGN.md` §5b | when asked |
| writer · reader | the one project that writes the tracker's files · every other project, which only reads them | |
