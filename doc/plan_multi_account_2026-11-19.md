# Plan: several Claude accounts on one machine (2026-11-19)

> **Status 2026-11-22: implemented, everything below is done; the "main account" this plan speaks of was removed the same day (schema v5: no `is_main`, `latest` = the account with the most room, one `quota_latest.<name>.json` per account, see `doc/design.md` §3.5).** Where the build differs from this plan: account **a** is now `~/.claude/account-a/` like b (layout symmetrical since 2026-11-21; this plan says "a = `~/.claude`" and "`is_main` = the default folder": a is the main account by name, the folder is no longer special); the picking of the account by quota (Phase 4) is "most room left", for `claude -p`, SDK and no-terminal calls; the 5-minute `slots` by account (Phase 4) exist (`slots.account`); `claude-account` is `~/.claude`'s `claude` on every PATH, not an alias. The overview for the user, with the decisions and the lessons: `/Users/jeanlescut/dev/infra/my-setup/doc/claude_accounts.html`.


Written by Claude Opus for an implementer (Claude Sonnet). The user decided the design below. Change a **decision** only by asking the user. Pick freely only the details marked *(free)*.

## 0. Context: what already exists

| Piece | Where | State |
|---|---|---|
| `claude-account` wrapper; `claude` is an alias for it | my-setup `files/claude_account.sh` (commit `dc75d27`), deployed `~/opt/my-setup/bin/claude-account` | ✅ installed on the Mac |
| Account **a** | `~/.claude` itself + `~/.claude.json` + Keychain item `Claude Code-credentials` (Linux: `~/.claude/.credentials.json`) | the user's main account, org `735a1078-9c43-4e63-85fa-ab5794a29aca`, Max |
| Account **NAME** (e.g. `b`) | `~/.claude/account-NAME/`: own `.claude.json` + own login; links `../<item>` for the shared items | created by `claude-account --add NAME`, then `claude --account NAME` and `/login` |
| Env of every session started by the wrapper | `CLAUDE_ACCOUNT=<name>`; `CLAUDE_CONFIG_DIR=~/.claude/account-NAME` for NAME ≠ a (unset for a) | inherited by hooks and by the status line command (`agent-tracker tick \| statusline-command.sh`) |
| Proof of concept on the VM | `~/.claude/{shared,account-a,account-b}` on H-Frank-1 | all shared features work; **remove at the end** (§7) |

**The bug to fix:** agent-tracker treats the quota as one account. A session on account b would write b's percents into `account_quotas.db` and `quota_latest.json`. Every reader would then show b's numbers as a's. **Until this plan is deployed, nobody uses account b on the Mac** (the user knows).

Vocabulary (repo `AGENTS.md`, plus these):

| Word | Means |
|---|---|
| **account** | one claude.ai login. Its stable id is the **organization uuid** (`oauthAccount.organizationUuid` in its `.claude.json`; header `anthropic-organization-id` of the quota API; `organization.id` in telemetry) |
| **account name** | the local short name: `a`, `b`… (`CLAUDE_ACCOUNT`); only meaningful on one machine |
| **main account** | account `a` on this machine: what a plain `claude`, every scheduled job and every reader means today |

## 1. Decisions (made by the user and Opus)

| # | Decision | Why |
|---|---|---|
| D1 | A reading's account = its **organization uuid**, in a new typed column `account_quotas.account` and in `raw` (`"account"`). NULL = before 2026-11-19 = the main account (insert-only: never backfill). | The uuid is the same on every machine; names are local |
| D2 | **Every existing reader stays correct unchanged.** `latest` view, `quota_latest.json`, `statusline_payload_reader.py` = **the main account only** | Five readers depend on them: agent-statusline, agent-quota, tasks (`src/launch/step.py`), auto-job-apply (`limits.py`), trading-bot killswitch. Scheduled jobs run plain `claude` = account a |
| D3 | New, for the other accounts: view `latest_by_account` (one row per account) and files `data/claude/quota_latest.<name>.json` (same shape as `quota_latest.json`, plus `"account"` and `"account_name"`) | Additive; `FOR_READERS.md` documents them |
| D4 | Machine-local table `accounts(name, org_uuid, config_dir, is_main, seen_ts)` in `account_quotas.db`, written only by the gate (new `--accounts` mode or a function called by the poller) | Maps uuid ↔ local name; lets `latest` filter the main account in SQL |
| D5 | The quota poller polls **every** local account, each with its own token, its own `--if-older-than` freshness and its own 429 wait | Each account's quota has no history except what we poll |
| D6 | `tick`: reading's account from the session's env (`CLAUDE_CONFIG_DIR` → that folder's `.claude.json`; unset → `~/.claude.json`), through a **cache** (D7). Account unknown → store **no** quota reading and offer nothing (never guess) | No wrong attribution |
| D7 | Cache `data/claude/accounts.json`: `{config_dir: {name, org_uuid}}`, rewritten by the poller each run (reads the `.claude.json` files; `~/.claude.json` is ~330 KB) | `tick` must stay < 150 ms (AGENTS.md rule) |
| D8 | Usage by account (user's #7): the telemetry `organization.id` attribute becomes a typed column `telemetry.account`; lifecycle `start` lines get `"account": <name>`. **Aggregates (`slots`) by account: not now** (Phase 4, only if the user asks) | Telemetry already carries it for free |
| D9 | Status line (user's #8): a session shows **its own account's** quota; the line also shows each **other** account's week %, e.g. `· b 12%w` | The user asked "perfect" for this |
| D10 | Schema change via a new idempotent, archiving step in `adhoc_quotas_analysis/migrate_to_target.py` (like `ADD COLUMN machine`, line ~275); `SCHEMA_VERSION` 3 → 4 | Repo rule: layout changes are a hand-run step that archives first; `install.sh` has no migration logic |

## 2. Phase 1: the gate and the schema (agent-tracker `src/`)

1. **`usage_db.py`**:
   - In `ACCOUNT_SCHEMA`, add `account TEXT` (comment: the organization uuid, also in raw since 2026-11-19; NULL: before = the main account) and the index `account_quotas_account ON account_quotas(account, ts)`.
   - Add the table `accounts` (D4).
   - Change the view `latest`: add `WHERE (account IS NULL OR account = (SELECT org_uuid FROM accounts WHERE is_main = 1))` inside its subquery. If the `accounts` table is empty (no poller run yet), the subquery returns NULL. Then `latest` must still return the newest NULL-account row; test this.
   - Add the view `latest_by_account`: the same reset rule, one row per `COALESCE(account, main uuid)`, with `account` and the local `name` (LEFT JOIN accounts).
   - `SCHEMA_VERSION = 4`.
2. **`adhoc_quotas_analysis/migrate_to_target.py`**: a new subcommand *(free name, e.g. `accounts-v4`)*. It archives `account_quotas.db` first (same way as the existing steps), then `ADD COLUMN account`, creates the index, the table and both views (drop + create), and sets `user_version = 4`. Idempotent: a second run changes nothing.
3. **`ingest_account_quota.py`**:
   - `columns()`: `account` = `d_row.get("account")`. For `claude_api` rows that lack it, fall back to `api_headers["anthropic-organization-id"]`. Validate it as a uuid (else `ValueError`).
   - Insert `account` like `machine` (only when the column exists).
   - The per-session dedup stays per session (unchanged).
   - The sync carries `raw`, so the account travels with it. Check that `add_synced` stores the column from raw.
   - A function to upsert the `accounts` table *(free signature)*, called by the poller (§3). It is still "the gate writes", so `tests/test_repo_hygiene.sh` stays green.
4. **Tests** (`tests/test_account_gate.sh`, `tests/test_ingest_claude_statusline.sh`):
   - Account extracted from a statusline row and from an api row (header fallback).
   - Invalid account rejected.
   - `latest` returns only main/NULL rows when a b row is newer.
   - `latest_by_account` returns one row per account.
   - Empty `accounts` table.
   - The migration step is idempotent on a copy of a v3 database (`tests/test_migrate_to_target.sh`).

## 3. Phase 2: the collectors (agent-tracker `src/`, `jobs/`)

1. **Local accounts** *(new small module, free name, e.g. `src/claude_accounts.py`)*: `local_accounts()` returns `[{name, config_dir, org_uuid, token_locator}]`.
   - Account a: `~/.claude.json`, Keychain `Claude Code-credentials` / `~/.claude/.credentials.json`.
   - Each `~/.claude/account-*/`: its `.claude.json`; on Linux `<dir>/.credentials.json`; on macOS a Keychain item whose service name **must be discovered** (step 3).
   - It writes the cache `data/claude/accounts.json` (D7) and upserts the `accounts` table (D4).
2. **`claude_quota_api_poller.py`**:
   - Loop over `local_accounts()`.
   - Per account: freshness `newest_age(account)` (newest reading **of that account**, any source, any machine), skip if young.
   - Token: `fetch_token(locator)`.
   - Row: add `"account": org_uuid, "account_name": name` before handing it to the gate.
   - The 429 Retry-After state is kept **per account**. The job wrapper `jobs/claude-quota.sh` maps exit 75 to WAIT. Decide *(free)* how one account's WAIT combines with another's success; simplest: one poller run per account from `claude-quota.sh`, and a WAIT only if every account waits.
   - Then `offer_quota_from_db` for every account (§3.4).
   - Keep "one start = at most one attempt" **per account**.
3. **macOS Keychain service name of a non-default config dir**: not documented. After the user has run `claude-account --add b` + `/login` on the Mac (ask them), list the item names with `security dump-keychain | grep -a '"svce"' | grep -i claude`. That command prints attributes only, **never** use `-d`, and never print a password. Record the rule (e.g. `Claude Code-credentials-<hash of config dir>`) in `doc/upstream.md`. The first `security find-generic-password -s <that name> -w` may open a macOS "allow access" dialog: ask the user to click **Always Allow** once.
4. **`agent_tracker.py`**:
   - `offer_quota(agent, …, account_name=None)`: `account_name` None or `a` writes `quota_latest.json` (unchanged). Otherwise it writes `quota_latest.<name>.json` with `"account"` and `"account_name"` added. Keep one flock per file.
   - `offer_quota_from_db(agent, account=None)`: the newest reading of that account (main = `account IS NULL OR account = main uuid`).
   - `cmd_tick` / `offer_quota_from_payload`: look up the session's account in `accounts.json` (key: `CLAUDE_CONFIG_DIR` or `~/.claude`). Unknown → skip the quota part (D6).
   - `statusline_usage.store()`: pass the account into the statusline row (`"account": uuid`) so the gate stores it. Unknown account → do not hand the quota row to the gate (the session cost row is still stored).
   - `append_lifecycle("start")`: add `"account": os.environ.get("CLAUDE_ACCOUNT") or "a"`. The line must stay < 512 bytes (existing guard).
   - `tick` must stay < 150 ms and never fail: measure it (`tests/test_agent_tracker.sh` has timing checks, extend them).
5. **Telemetry (D8)**: the gate that stores telemetry rows (find it from `telemetry_receiver.py` → its `ingest_*`) extracts `attributes["organization.id"]` into a new column `telemetry.account`. Add it to `SESSIONS_SCHEMA` and as a migration step (same pattern as D10, same subcommand or a second one).
6. **Tests**:
   - The poller with two fake accounts (stub `fetch_token`/`fetch_usage`; tests already stub them in `tests/test_poll_claude.sh`): two rows with two accounts; per-account freshness; per-account 429.
   - `tick` with `CLAUDE_CONFIG_DIR` set to an account-b folder of the temp runtime writes `quota_latest.b.json` and leaves `quota_latest.json` untouched.
   - Unknown account: nothing written.
   - The lifecycle line has `account`.
   - **Every test points at a temp runtime** (`AGENT_TRACKER_HOME`). Never the real `~/.claude`: set `HOME` to a temp dir too.

## 4. Phase 3: the readers

1. **agent-statusline** (`~/dev/agents/agent-statusline/providers/claude-statusline-command.sh`; its own repo and README; commit there):
   - `quota_file` = `quota_latest.json` when `CLAUDE_ACCOUNT` is empty or `a`, else `quota_latest.$CLAUDE_ACCOUNT.json`.
   - Show the account when it isn't `a` *(free placement, e.g. `[b]` before the model)*.
   - Add the other accounts' week % (D9): read every other `quota_latest*.json`, apply the same reset rule, render ` · b 12%w` *(free exact format; keep it short)*.
   - Its tests, if any (`tests/`).
   - Contract note in its README "agent-tracker" section.
2. **agent-quota** (`~/dev/agents/agent-quota`, the PreToolUse hook on every tool): today it reads the main account. A session on b would be throttled by a's quota. **Minimal fix:** when `CLAUDE_ACCOUNT` is set and ≠ `a`, read `quota_latest.<name>.json` / `latest_by_account`. If that is not trivial, do nothing and add a Todoist task for it (skill `tasks`, `Repo: agent-quota`). Either way, tell the user.
3. **tasks, auto-job-apply, trading-bot killswitch**: no change (D2: they run on account a). Mention them in `FOR_READERS.md`.

## 5. Phase 4 (not now)

`slots` by account (aggregates), and "always account a unless it is saturated, then b". The latter needs `claude-account` (my-setup) to read `latest_by_account` or the `quota_latest*.json` files. Create one Todoist task each (skill `tasks`, `Repo: agent-usage-tracker` / `Repo: my-setup`), don't build them.

## 6. Docs (repo rules: one fact, one file)

| File | Change |
|---|---|
| `FOR_READERS.md` | §4: `quota_latest.<name>.json`, `account` column, `latest` = main account, `latest_by_account`, `accounts` table, `accounts.json` |
| `doc/tables.md` | the new columns, table and views; "Last verified" line |
| `doc/changes.md` | one dated row per captured change (2026-11-19 or the real date) |
| `doc/design.md` **and** `README.html` | together (rule): the multi-account flow, in one small diagram |
| `doc/upstream.md` | the Keychain service name rule (§3.3); `organization.id` in telemetry |

## 7. Deploy and verify (order matters)

1. `bash tests/run.sh` green (log to a file, read only failures: the user has few tokens).
2. Commit in agent-tracker (and agent-statusline, agent-quota). Use the trailers of the global rules. Never push.
3. **Mac**: `bash ~/dev/agents/agent-tracker/install.sh`, then the migration step(s) of D10 on `~/opt/agent-tracker/data/claude/*.db` (they archive first).
4. **NAS** (the central, `ssh babisnas`; a home-LAN host, `babisnas-tailscale` when away): the same code must run there, because the sync stores raw rows through the NAS's gate. Follow `doc/deploy_migration.md` / `design/DEPLOY.md` for how code reaches the NAS (rsync to `~/dev/agents/agent-tracker`, `install.sh`), then run the migration step there. **Ask the user before touching the NAS** if those docs leave any doubt.
5. **VM** (H-Frank-1): it also runs the poller (`SILENT_AFTER_MIN@H-Frank-1` in `claude-quota.conf`). Deploy the same way, migrate. Then remove the proof of concept there:
   - Look first, then delete one literal path at a time: `~/.claude/shared`, `~/.claude/account-a`, `~/.claude/account-b`, `~/.claude/poc-claude-acct.sh`, `~/claude-poc-work`.
   - Its PoC logins are separate grants, so removing them doesn't affect the VM's real login.
   - Check first that no PoC Claude process is running (`pgrep -af claude`).
6. **Live check with the user** (they log in; you watch):
   1. `claude-account --add b` on the Mac (already done if §3.3 was), `claude --account b`, `/login` as account b.
   2. Within 2 min: `sqlite3 ~/opt/agent-tracker/data/claude/account_quotas.db 'SELECT name, org_uuid, is_main FROM accounts'` shows a and b. `latest_by_account` shows two rows. `latest` and `quota_latest.json` still show **a's** week % (it was 82–85% on 2026-11-19). `quota_latest.b.json` exists.
   3. The status line in the b session shows b's own %. An a session shows a's own % and `· b N%w`.
   4. `agent-tracker check` reports no problem; the claude-quota job dashboard is green.
7. Tell the user it's done and that account b can now be used on the Mac. Give one table: what changed, where, and what was not done (Phase 4, any agent-quota task).

## 8. Guardrails (from the user's rules; read `~/.claude/CLAUDE.md`)

- Token-conscious: long commands go to a log file, read only the tail/failures.
- Never `rm` a glob or a variable path; delete named files one at a time after looking.
- Never print or log a token. The Keychain stage logs only exception **types** (existing rule in the poller).
- Tests that start tmux run under `tests/run_with_test_tmux.sh`.
- Every commit ends with the `Co-Authored-By`, `Agent:`, `Machine:` and `Session:` trailers. Get `Machine:` with skill `machine-name`.
- Answer the user briefly, tables over prose, full paths in backticks.
