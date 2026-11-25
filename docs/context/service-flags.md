# Service flags (flags as code)

A short allowlist of operational settings is flipped by a reviewed PR to
engram-infra, never by an rpc. The backend reads the file; it has no admin
endpoint and no write path for it.

- Backend: `lib/engram/service_config/flags.ex` (reader), precedence in
  `Engram.ServiceConfig.Overrides.fetch/1`.
- Infra: `service_flags/schema.json`, `bin/check-service-flags`,
  `main/envs/{prod,staging-fastraid}/service_flags.json` and its doc
  `docs/context/service-flags-as-code.md` (engram-infra).

## Keys

Exactly the schema's properties (`Overrides.flag_keys/0`; change both
together): `folder_marker_delete`, `folder_marker_delete_max_fixed`,
`folder_ops`, `client_logs_stop_writes`, `plugin_floor_enabled`,
`plugin_floor`, `paused_accounts`. Every key is optional; absent means the
DB override or the code default. Values are checked with the same validator
as a DB override (`Overrides.validate/2`).

`paused_accounts` is flags-only: `[{"id": <uuid>, "until": <UTC ISO 8601, ends Z>}]`,
at most 1000. `Engram.ClientGate.paused/1` (HTTP, socket join, the +61 s
`QuarantineDisconnect` job) treats a user as paused if the billing-override
quarantine row says so OR the id has an unexpired entry. `until` is judged
against the clock on every read, so an expired entry needs no revert PR.

## Sources

| Env | Source | Env vars |
|-----|--------|----------|
| SaaS prod | AWS AppConfig Data API, task role | `SERVICE_FLAGS_APPCONFIG_{APPLICATION,ENVIRONMENT,PROFILE}`, `AWS_REGION` |
| Staging | file, re-read every 60 s | `SERVICE_FLAGS_FILE=/etc/engram/service_flags.json` |
| Self-host, test | none: no reader starts | neither |

AppConfig: `StartConfigurationSession` once, then `GetLatestConfiguration`
every 60 s with the next-poll token. An empty body means unchanged. Any
failure (including the BadRequest of a token past its 24 h life) drops the
session and the next poll starts a new one. ex_aws has no AppConfig Data
service (its endpoint table has no `appconfigdata`), so Req signs the call
(SigV4, signing name `appconfig`) with credentials from ex_aws's chain, the
same task role S3 and KMS use.

## Precedence

`flag > DB override (service_overrides) > env/default`, in one place:
`Overrides.fetch/1`, which every `ServiceConfig.get/2` of an allowlisted key
goes through (`PluginVersion.effective_minimum/0` included, which still
judges `plugin_floor`'s `expires_at` on every read).

Where a source is configured, `ServiceConfig.override/3` and `clear/2` (and
so `ClientLocks.lock_plugin_version` and `lift_plugin_lock`) return
`{:error, :managed_by_flags}` for a flag key. Every other key keeps its DB
path. Self-host keeps the DB path for every key except `paused_accounts`.

`ServiceConfig.effective/0` lists every key's value in force on that node and
its source (`:flags`, `:db`, `:env`).

**Stale DB rows still apply when the flag is absent.** A row written for a
flag key before flags shipped is read whenever the file does not set that
key, and it can no longer be cleared through `ServiceConfig.clear/2` on prod
or staging. Before the first prod flip, check `ServiceConfig.list()` for rows
under the keys above and either set the key in the file (the flag wins) or
delete the row by hand.

## Fail-safe

- Source unreachable, or the document is not JSON, has a duplicate key at any
  depth, or is not an object: the last good map stays, with one warning per
  state change (`service flags source unreachable` / `service flags document
  invalid`, then `service flags source healthy again`), not one per poll.
- A node that has never loaded (boot with the source down) serves an empty
  map: DB overrides and defaults apply.
- An unknown key is dropped; a bad value keeps that key's previous value.
  One `service flag rejected key=...` error line each; the other keys apply.
- The map lives in `:persistent_term` and is written only when it changes (a
  put is a global GC). Reads are one lookup and never query.
- The reader never touches the database.

Each node polls on its own, so nodes converge within one poll (60 s) of each
other. There is no cache to evict: `fetch/1` reads the term directly.

## Flip procedure

1. On an engram-infra branch, edit `main/envs/<env>/service_flags.json`
   (`prod` or `staging-fastraid`). Run `bin/check-service-flags`.
2. Open the PR, comment `/tf-plan`, get it reviewed, merge. The main-push
   apply deploys it (prod: a new AppConfig hosted version and deployment;
   staging: the `engram-saas` container is recreated). Merge rules and
   rollback are in engram-infra `docs/context/service-flags-as-code.md`.
3. Revert = a revert PR, applied the same way.

## Verify a flip

Each node logs one line per changed key, `:data` category, warning level
(ships to Loki):

```logql
{service_name="engram", env="prod"} |= "service flag changed key=<key>"
```

e.g. `service flag changed key=folder_ops old=false new=true source=appconfig`.
Expect one line per running task (web and worker) within about a minute of
the apply. `paused_accounts` logs counts and HMAC-hashed ids, never a raw id:
`old=1 new=2 added=[<hash>] removed=[] source=appconfig`; match a user with
`Engram.Crypto.HMAC.hash_user_id/1`. No line at all within two minutes:
search the same stream for `service flags source unreachable`,
`service flags document invalid` and `service flag rejected`.

A newly paused or lifted id has its sockets dropped
(`SessionInvalidator.disconnect_user/1`) by every node that sees the change;
expiry alone is noticed on the client's next request or join, and logs
`service flag paused_accounts entry expired, ignored user=<hash>` once per
node.

## Runbook: folder marker delete (`folder_marker_delete`)

Switched on only once release E is verified and the #2523 re-probe reads 0
(`Engram.DataMigrations.FolderMarkerDelete`).

1. PR setting `"folder_marker_delete": true` (and, to change the pace,
   `"folder_marker_delete_max_fixed": <1..100000>`, default 2000 a pass).
2. Verify the flag line above for each task, then the next hourly pass:
   `{service_name="engram", env="prod"} |= "folder_marker_delete"` shows its
   skip warnings, and the ledger closes when no markers are left.
3. Stop: a PR setting it `false` (or removing it: default off). The next
   pass returns before any work.

## Runbook: pause an account (`paused_accounts`)

Replaces `ClientLocks.quarantine_user` rpc on prod and staging. Add
`{"id": "<user uuid>", "until": "<at most 30 days ahead, UTC, ending Z>"}`;
lift by removing the entry, or let `until` pass. The user gets
`account_paused` (HTTP 403, join refused) from the first node that polls.

## Runbook: plugin floor (`plugin_floor`, `plugin_floor_enabled`)

Replaces `ClientLocks.lock_plugin_version` / `lift_plugin_lock` rpc. Set
`plugin_floor` to `{"min", "update_to", "expires_at", "reason"}` (the
checker enforces `update_to >= min`, a 1..200 byte reason and `expires_at` at
most 30 days ahead); `plugin_floor_enabled: false` ignores any lock. A
change drops `user:` sockets below the old or the new min
(`ClientLocks.recheck/1`, as the rpc did) so they rejoin against it. Check
the published plugin version and the Tempo client versions first, as
`Engram.Admin.ClientLocks` describes: nothing checks `update_to` against the
manifest on this path.
