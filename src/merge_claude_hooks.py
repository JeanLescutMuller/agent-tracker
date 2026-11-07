#!/usr/bin/env python3
"""Adds or removes agent-tracker's two hooks in the `hooks` object of Claude
Code's settings.json, touching nothing else: a SessionStart group running
`agent-tracker hook start` and a SessionEnd group running `agent-tracker hook
end` (DESIGN.md §4).

`hooks` is shared (skill config-ownership): every tool owns only its own
groups, recognised by their command. Ours are the groups whose command
contains "agent-tracker hook "; set replaces them (so a re-run never adds a
second one), unset removes them; every other group stays as it is.

Usage: merge_claude_hooks.py set|unset
Env:   CLAUDE_SETTINGS (default $CLAUDE_CONFIG_DIR/settings.json, else ~/.claude/settings.json)
Prints one of: changed, unchanged, absent.
"""
import json
import os
import sys
from pathlib import Path

MARK = "agent-tracker hook "
# The full path (unquoted, so the command holds "agent-tracker hook "): a hook must not depend on
# ~/.local/bin being on Claude Code's PATH.
COMMANDS = {"SessionStart": "$HOME/.local/bin/agent-tracker hook start",
            "SessionEnd": "$HOME/.local/bin/agent-tracker hook end"}

settings_path = Path(os.environ.get("CLAUDE_SETTINGS") or
                     Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "settings.json")
mode = sys.argv[1]

if not settings_path.exists():
    if mode == "unset":
        print("absent")
        sys.exit(0)
    d_settings = {}
else:
    d_settings = json.loads(settings_path.read_text())


def ours(d_group) -> bool:
    return isinstance(d_group, dict) and any(MARK in str(h.get("command", "")) for h in d_group.get("hooks") or []
                                             if isinstance(h, dict))


d_hooks = dict(d_settings.get("hooks") or {})
for event, command in COMMANDS.items():
    l_groups = [g for g in d_hooks.get(event) or [] if not ours(g)]
    if mode == "set":
        l_groups.append({"matcher": "", "hooks": [{"type": "command", "command": command}]})
    if l_groups:
        d_hooks[event] = l_groups
    else:
        d_hooks.pop(event, None)

d_new = dict(d_settings)
if d_hooks:
    d_new["hooks"] = d_hooks
else:
    d_new.pop("hooks", None)

if d_new == d_settings:
    print("unchanged")
else:
    # Temp file + rename: a Claude Code starting meanwhile never reads half a file.
    tmp = settings_path.with_suffix(".json.tmp")
    tmp.parent.mkdir(parents=True, exist_ok=True)
    tmp.write_text(json.dumps(d_new, indent=2) + "\n")
    tmp.replace(settings_path)
    print("changed")
