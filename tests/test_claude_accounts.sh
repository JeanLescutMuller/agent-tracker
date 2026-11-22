#!/bin/bash
# Tests for src/claude_accounts.py: the Claude accounts of one machine (2026-11-19): which are logged in, their
# organization uuid, the Keychain service name, the cache `tick` reads, the account of a session. A sandbox HOME and
# runtime; never a token (only names and uuids).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

SRC_DIR="$REPO_ROOT/src"
S="$(mktemp -d "${TMPDIR:-/tmp}/th-accounts.XXXXXX")"
trap 'rm -rf "$S"' EXIT
export HOME="$S/home" AGENT_TRACKER_HOME="$S/rt"
unset CLAUDE_CONFIG_DIR
UA="11111111-1111-4111-8111-111111111111"; UB="22222222-2222-4222-8222-222222222222"
py() { python3 -c "import sys, json; sys.path.insert(0, '$SRC_DIR'); import claude_accounts as c
$1"; }

section "a machine with no login: the main account alone, no uuid"
mkdir -p "$HOME/.claude"
assert_eq "a, unknown uuid, main" "a None True" "$(py "a = c.local_accounts(); print(len(a) == 1 and f\"{a[0]['name']} {a[0]['org_uuid']} {a[0]['is_main']}\")" | sed 's/^True$/a None True/')"
assert_eq "the default folder is the main account without any cache" "a" "$(py "print(c.session_account({})['name'])")"
assert_eq "another folder, not in the cache: unknown (never guessed)" "None" "$(py "print(c.session_account({'CLAUDE_CONFIG_DIR': '$HOME/.claude/account-b'}))")"

section "two accounts: names, uuids, folders"
echo '{"oauthAccount":{"organizationUuid":"'$UA'"}}' > "$HOME/.claude.json"
mkdir -p "$HOME/.claude/account-b" "$HOME/.claude/account-c" "$HOME/.claude/account-bad name" "$HOME/.claude/projects"
echo '{"oauthAccount":{"organizationUuid":"'$UB'"}}' > "$HOME/.claude/account-b/.claude.json"
echo '{"oauthAccount":{"organizationUuid":"not-a-uuid"}}' > "$HOME/.claude/account-c/.claude.json"
assert_eq "a, b (c: bad uuid kept as not logged in; a folder with a space is no account)" "a $UA|b $UB|c None" \
    "$(py "print('|'.join(f\"{x['name']} {x['org_uuid']}\" for x in c.local_accounts()))")"
assert_eq "only the main one is main" "a" "$(py "print(','.join(x['name'] for x in c.local_accounts() if x['is_main']))")"

section "the cache tick reads: only the logged-in accounts, rewritten only on a change"
py "c.write_cache(c.local_accounts())"
assert_eq "a and b" "a b" "$(jq -r '.accounts | to_entries | map(.value.name) | join(" ")' "$AGENT_TRACKER_HOME/data/claude/accounts.json")"
T1="$(stat -f %m "$AGENT_TRACKER_HOME/data/claude/accounts.json" 2>/dev/null || stat -c %Y "$AGENT_TRACKER_HOME/data/claude/accounts.json")"
sleep 1.1; py "c.write_cache(c.local_accounts())"
assert_eq "unchanged content: not rewritten" "$T1" "$(stat -f %m "$AGENT_TRACKER_HOME/data/claude/accounts.json" 2>/dev/null || stat -c %Y "$AGENT_TRACKER_HOME/data/claude/accounts.json")"
assert_eq "a session on account b" "b $UB" "$(py "x = c.session_account({'CLAUDE_CONFIG_DIR': '$HOME/.claude/account-b/'}); print(x['name'], x['org_uuid'])")"
assert_eq "a session on the default folder" "a $UA" "$(py "x = c.session_account({}); print(x['name'], x['org_uuid'])")"

section "account a in its own folder (2026-11-21): once ~/.claude/account-a holds a login, a is a folder like b"
mkdir -p "$HOME/.claude/account-a"
echo '{"hasCompletedOnboarding":true}' > "$HOME/.claude/account-a/.claude.json"
assert_eq "a folder without a login: a stays legacy (the default folder)" "$(py "print(c.norm('$HOME/.claude'))")" "$(py "print(c.local_accounts()[0]['config_dir'])")"
assert_eq "...and not moved" "False" "$(py "print(c.a_moved())")"
UA2="33333333-3333-4333-8333-333333333333"
echo '{"oauthAccount":{"organizationUuid":"'$UA2'"}}' > "$HOME/.claude/account-a/.claude.json"
assert_eq "a logged in at its folder: moved, its own uuid" "True $(py "print(c.norm('$HOME/.claude/account-a'))") $UA2" "$(py "a = c.local_accounts()[0]; print(c.a_moved(), a['config_dir'], a['org_uuid'])")"
assert_eq "...still the main account, listed first, b after it" "a True|b False|c False" "$(py "print('|'.join(f\"{x['name']} {x['is_main']}\" for x in c.local_accounts()))")"
assert_eq "...no account-a twice" "1" "$(py "print(sum(x['name'] == 'a' for x in c.local_accounts()))")"
assert_match "...its Keychain item is the hashed name, like b's" "$(py "print(c.service_name('$HOME/.claude/account-a'))")" "^Claude Code-credentials-[0-9a-f]{8}$"
assert_eq "...the default folder keeps Claude Code's own name (legacy sessions still running)" "Claude Code-credentials" "$(py "print(c.service_name('$HOME/.claude'))")"
py "c.write_cache(c.local_accounts())"
assert_eq "a session on a's folder" "a $UA2" "$(py "x = c.session_account({'CLAUDE_CONFIG_DIR': '$HOME/.claude/account-a'}); print(x['name'], x['org_uuid'])")"
assert_eq "a session still on the default folder (started before the move): a, uuid unknown" "a None" "$(py "x = c.session_account({}); print(x['name'], x['org_uuid'])")"
rm -r "$HOME/.claude/account-a"

section "the Keychain service name: Claude Code's own for the main account, a folder hash for another"
assert_eq "main" "Claude Code-credentials" "$(py "print(c.service_name('$HOME/.claude'))")"
assert_match "another: the first 8 hex of the folder's sha256" "$(py "print(c.service_name('$HOME/.claude/account-b'))")" "^Claude Code-credentials-[0-9a-f]{8}$"
assert_ne "...a different one per folder" "$(py "print(c.service_name('/x/a'))")" "$(py "print(c.service_name('/x/b'))")"
assert_match "Linux: the login blob of an account is in its own folder" "$(py "print(c.credentials_file('$HOME/.claude/account-b'))")" "/account-b/\\.credentials\\.json$"

harness_summary
