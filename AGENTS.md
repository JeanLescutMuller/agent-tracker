# agent-tracker

Design stage (2026-11-07): nothing is built yet. Read [`DESIGN.md`](DESIGN.md) first; the page for the user is [`design.html`](design.html) (same content, with colors and diagrams). Both must say the same thing: change them together.

Goal, in the user's words (2026-11-07): one project that knows "what is running exactly where, what was open, what was exited, for each session when was the last time I sent a prompt, when was the last time we detected the session being open on the laptop", so that asm, notify, the statusline and the crash restore stop each keeping their own copy ("a unix approach, with no overlap").

## Vocabulary

| Word | Means | Never say |
|---|---|---|
| Claude session | one conversation of Claude Code (or Codex), named by its UUID | "session" alone, when a tmux session could be meant |
| tmux session · window · pane | tmux's own words; a pane is named by tmux's `%id` (stable while tmux runs) and shown as `<tmux session>:<window>.<pane>` | |
| event | one line the tracker appends when a hook fires: start, prompt, stop, waiting, end | |
| last prompt | time of the user's last message in a Claude session (from the `prompt` event) | last active |
| last seen | last time the statusline was drawn for a Claude session (every 10 s while it is open) | heartbeat (that word stays the statusline's own per-agent file) |
| boot | one run of the Mac, from power-on to shutdown or crash; named by its start time `boot_ts` | |
| open at crash | a Claude session of the previous boot that never got an `end` event | |
| writer · reader | the one project that writes the tracker's files · every other project, which only reads them | |
