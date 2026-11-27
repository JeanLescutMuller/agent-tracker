#!/bin/bash
# ~/opt/agent-tracker/quota-rules.sh: job agent-tracker.quota-rules.
# Requirements (src/quota_rules.py, FOR_READERS.md §4):
#   - data/claude/quota_rules.json: each account's plan, its 5-hour windows per week (measured, per plan), points per
#     1% of each meter, its fixed weekly reset and its monthly billing day (~/.config/agent-tracker/billing.json)
#   - Mac and NAS, each for itself (the readings are the same on both; the logins are local); hourly tick
#   - timeout 2 min, far shorter than the tick: no claim
#   - summary: its last line ("written: a: 7.33 5h/week, resets Mon 19:00Z · b: …")
. ~/opt/job-runner/lib.sh
jr_execute 2 python3 src/quota_rules.py
