#!/usr/bin/env python3
"""The Claude accounts of THIS machine (2026-11-19; my-setup's `claude-account`, doc/plan_multi_account_2026-11-19.md).

  account NAME ~/.claude/account-NAME/ (CLAUDE_CONFIG_DIR of its sessions): its own .claude.json and login. All accounts are alike.
               The one named a was Claude Code's default folder ~/.claude (its login: ~/.claude.json and the Keychain item
               "Claude Code-credentials", on Linux ~/.claude/.credentials.json) until it holds a login in ~/.claude/account-a/
               (a_moved(), 2026-11-21); until then that folder is its place, so a deploy before the login is safe

An account's id is its organization uuid (`oauthAccount.organizationUuid` of its .claude.json), the same on every
machine. `local_accounts()` lists the accounts that are logged in; `write_cache()` keeps them in
data/claude/accounts.json, which `agent-tracker tick` reads (it must stay fast: ~/.claude.json is ~330 KB) and records
them in the `accounts` table through the gate. Never reads or prints a token: `service_name()` only names the Keychain item.
"""
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

import usage_db

KEYCHAIN_SERVICE = "Claude Code-credentials"
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
NAME_RE = re.compile(r"[a-z0-9_-]+")


def home_dir() -> Path:
    return Path.home() / ".claude"


def norm(path) -> str:
    """The key of a config folder: absolute, no trailing slash."""
    return os.path.normpath(str(path))


def _org_uuid(claude_json: Path) -> str | None:
    try:
        uuid = (json.loads(claude_json.read_text()).get("oauthAccount") or {}).get("organizationUuid")
    except (OSError, ValueError, AttributeError):
        return None
    return uuid if isinstance(uuid, str) and UUID_RE.fullmatch(uuid) else None


def a_folder() -> Path:
    return home_dir() / "account-a"


def a_moved() -> bool:
    """Account a lives in ~/.claude/account-a once that folder holds a login (my-setup's claude-account --login a): until then it
    is legacy, Claude's default folder ~/.claude with ~/.claude.json and the Keychain item "Claude Code-credentials"."""
    return _org_uuid(a_folder() / ".claude.json") is not None


def local_accounts() -> list[dict]:
    """[{name, config_dir, org_uuid (None when not logged in)}], by name. a is always listed (it is what an old,
    single-account setup polls): in its own folder once it has moved there, else legacy. Every other account is a folder
    ~/.claude/account-NAME."""
    home = home_dir()
    if a_moved():
        l_accounts = [{"name": "a", "config_dir": norm(a_folder()), "org_uuid": _org_uuid(a_folder() / ".claude.json")}]
    else:
        l_accounts = [{"name": "a", "config_dir": norm(home), "org_uuid": _org_uuid(Path.home() / ".claude.json")}]
    for folder in sorted(home.glob("account-*")):
        name = folder.name[len("account-"):]
        if folder.is_dir() and NAME_RE.fullmatch(name) and name != "a":
            l_accounts.append({"name": name, "config_dir": norm(folder), "org_uuid": _org_uuid(folder / ".claude.json")})
    return l_accounts


def service_name(config_dir: str) -> str:
    """macOS Keychain service of an account's login. Claude's default folder (~/.claude, or none): Claude Code's own name; any
    other folder (CLAUDE_CONFIG_DIR, every account folder since 2026-11-21, a included): that name + '-' + the first 8 hex of
    the sha256 of the folder path. Not documented by Anthropic; verified on the Mac on 2026-11-19 with a real second login
    (doc/upstream.md §3.5)."""
    if not config_dir or norm(config_dir) == norm(home_dir()):
        return KEYCHAIN_SERVICE
    return f"{KEYCHAIN_SERVICE}-{hashlib.sha256(config_dir.encode()).hexdigest()[:8]}"


def credentials_file(config_dir: str) -> Path:
    """Linux: where Claude Code keeps the login blob of an account."""
    return Path(config_dir) / ".credentials.json"


def cache_path() -> Path:
    return usage_db.RUNTIME_DIR / "data" / "claude" / "accounts.json"


def read_cache() -> dict:
    """{config_dir: {"name", "org_uuid"}} - empty when absent or unreadable. Fast: a few hundred bytes."""
    try:
        return json.loads(cache_path().read_text()).get("accounts") or {}
    except (OSError, ValueError, AttributeError):
        return {}


def write_cache(l_accounts: list[dict]) -> None:
    """Atomically, and only when the content changed (tick reads it on every render)."""
    d_new = {a["config_dir"]: {"name": a["name"], "org_uuid": a["org_uuid"]} for a in l_accounts if a["org_uuid"]}
    if read_cache() == d_new and cache_path().exists():
        return
    path = cache_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps({"ts": int(time.time()), "accounts": d_new}, indent=1))
    tmp.replace(path)


def session_account(env=None) -> dict | None:
    """The account of the session whose environment is `env` (default: ours): {"name", "org_uuid" (None when the cache
    does not know it yet), "config_dir"}, or None when unknown. The default folder is the account named a,
    so a single-account machine needs no cache; another folder must be in it: never guess (the quota of an unknown
    account is not recorded)."""
    env = os.environ if env is None else env
    key = norm(env.get("CLAUDE_CONFIG_DIR") or home_dir())
    d = read_cache().get(key)
    if d:
        return {"config_dir": key, **d}
    if key == norm(home_dir()):
        return {"config_dir": key, "name": "a", "org_uuid": None}
    return None


if __name__ == "__main__":
    # claude_accounts.py [--cache]: print the local accounts (name, org uuid, config folder); --cache also writes accounts.json
    l_accounts = local_accounts()
    if "--cache" in sys.argv[1:]:
        write_cache(l_accounts)
    for a in l_accounts:
        print(a["name"], a["org_uuid"] or "-", a["config_dir"])
