<!-- github-stub -->
# agent-tracker

**Track your Claude Code usage over time: the 5-hour and weekly quota percent, tokens and Claude Code's own $ cost, per session and per machine, so other tools (a status line, a quota manager) can read it.**

| | |
|---|---|
| Records | quota readings (5-hour and 7-day windows, reset times) and per-session tokens and $, from Claude Code's telemetry, status line and transcripts |
| Runs on | macOS (launchd) and Linux (systemd); quota readings shared between machines |
| Read by | [agent-statusline](https://github.com/JeanLescutMuller/agent-statusline), [agent-quota](https://github.com/JeanLescutMuller/agent-quota), any project ([FOR_READERS.md](FOR_READERS.md)) |

The full README, with diagrams: [README.html](https://htmlpreview.github.io/?https://github.com/JeanLescutMuller/agent-tracker/blob/main/README.html) · rules for agents: [AGENTS.md](AGENTS.md)
