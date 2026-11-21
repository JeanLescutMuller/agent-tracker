#!/usr/bin/env python3
"""The gate of data/<agent>/aggregates/<machine>.db (Category 3,
doc/design.md §6.3): the only code that writes one, this machine's own
and, on the VM, the Mac's copy (through receive_from_machine.py).

It checks each `slots` row - every column there, of the right type, ts a
multiple of 300, counts not negative, the machine of the file it goes into
(one file per machine, P14), no extra key (so never a quota percent:
doc/tables.md §1); a row without `job` (a sender older than 2026-11-20)
gets '' (and one without `account`, a sender older than 2026-11-21, gets '' too) - and inserts it
with INSERT OR IGNORE: a slot is written once, when final, and never
changes; the same slot sent twice is a no-op.
"""
import re
from pathlib import Path

import usage_db

SLOT_COLUMNS = ("ts", "dt", "machine", "folder", "entrypoint", "job", "account", "model", "requests", "input_tokens", "output_tokens",
                "cache_read_tokens", "cache_write_5m_tokens", "cache_write_1h_tokens", "cache_write_unknown_tokens",
                "usd", "tokens_without_usd", "written_ts")
COUNT_COLUMNS = ("requests", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_5m_tokens",
                 "cache_write_1h_tokens", "cache_write_unknown_tokens", "tokens_without_usd")
MACHINE_RE = re.compile(r"[A-Za-z0-9-]+")
ACCOUNT_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")   # an organization uuid


def check(d_slot: dict, machine: str) -> list:
    """The row's values in SLOT_COLUMNS order; ValueError when it must not be stored."""
    if isinstance(d_slot, dict) and "job" not in d_slot:
        d_slot = {**d_slot, "job": ""}   # a sender older than the column: no job known
    if isinstance(d_slot, dict) and "account" not in d_slot:
        d_slot = {**d_slot, "account": ""}   # a sender older than 2026-11-21: no account known
    if not isinstance(d_slot, dict) or set(d_slot) != set(SLOT_COLUMNS):
        raise ValueError(f"a slot has exactly the columns {SLOT_COLUMNS}")
    for key in ("ts", "written_ts") + COUNT_COLUMNS:
        if isinstance(d_slot[key], bool) or not isinstance(d_slot[key], int) or d_slot[key] < 0:
            raise ValueError(f"{key} is not a count: {d_slot[key]!r}")
    if d_slot["ts"] % 300:
        raise ValueError(f"ts is not a 5-min slot start: {d_slot['ts']}")
    if d_slot["dt"] != usage_db.iso(d_slot["ts"]):
        raise ValueError(f"dt {d_slot['dt']!r} is not ts {d_slot['ts']}")
    if not isinstance(d_slot["machine"], str) or not MACHINE_RE.fullmatch(d_slot["machine"]):
        raise ValueError(f"not a machine name: {d_slot['machine']!r}")
    if d_slot["machine"] != machine:
        raise ValueError(f"a slot of {d_slot['machine']!r} in the file of {machine!r}")
    for key in ("folder", "entrypoint", "job", "account", "model"):
        if not isinstance(d_slot[key], str):
            raise ValueError(f"{key} is not text: {d_slot[key]!r}")
    if d_slot["account"] != "" and not ACCOUNT_RE.fullmatch(d_slot["account"]):
        raise ValueError(f"account is neither '' nor an organization uuid: {d_slot['account']!r}")
    if d_slot["usd"] is not None and (isinstance(d_slot["usd"], bool) or not isinstance(d_slot["usd"], (int, float))):
        raise ValueError(f"usd is not a number: {d_slot['usd']!r}")
    return [d_slot[k] for k in SLOT_COLUMNS]


def add_slots(db, l_slots: list[dict]) -> int:
    """Inserts the slots in one transaction; returns how many were new.
    One bad row rejects the whole batch (ValueError): a slot is never
    written twice, so a partial batch could not be completed later.
    `db` is an aggregates/<machine>.db (usage_db.open_aggregates): every
    row must be that machine's."""
    machine = Path(db.execute("PRAGMA database_list").fetchone()[2]).stem
    l_values = [check(d, machine) for d in l_slots]
    if "account" not in [r[1] for r in db.execute("PRAGMA table_info(slots)")]:
        # A file not migrated yet (adhoc_quotas_analysis/migrate_to_target.py slots-account): rows that know no account
        # still fit its old key; one that knows an account would collide with another account's row and be lost, so it
        # fails loudly (the job shows it) until the migration has run.
        i_acct = SLOT_COLUMNS.index("account")
        if any(v[i_acct] for v in l_values):
            raise ValueError("slots has no account column yet: run migrate_to_target.py slots-account on this file")
        l_values = [v[:i_acct] + v[i_acct + 1:] for v in l_values]
        l_columns = [c for c in SLOT_COLUMNS if c != "account"]
    else:
        l_columns = list(SLOT_COLUMNS)
    db.execute("BEGIN IMMEDIATE")
    try:
        n = sum(db.execute(f"INSERT OR IGNORE INTO slots ({', '.join(l_columns)}) "
                           f"VALUES ({','.join('?' * len(l_columns))})", values).rowcount for values in l_values)
        db.execute("COMMIT")
    except BaseException:
        db.execute("ROLLBACK")
        raise
    return n
