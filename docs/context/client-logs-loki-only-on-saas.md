# Client logs: Loki only on SaaS, `client_logs` for CI and self-host

_Verified 2026-11-21 against prod._

Goal: SaaS writes no `client_logs` rows. Every line the table would have kept
ships to Loki (`Engram.Logs.reemit_to_logger/2`). CI and self-host keep
writing the table, and `GET /api/logs` keeps working there.

**Status: built, not on.** The switch ships OFF, so SaaS still writes rows.
The same release is the first to ship allowlisted info lines and stacks to
Loki, and the parity check (below) covered warn and error only; stopping
writes in that release would leave no period with both copies.

## Switch

- `client_logs_stop_writes`, a `Engram.ServiceConfig.Overrides` key (boolean).
  Default: **false** (rows are written). `true` stops row writes on SaaS.
  CI and self-host ignore it: `Engram.Logs.writes_stopped?/0` requires
  `:client_logs_persist_all` false, and
  `Engram.RuntimeConfig.client_logs_persist_all?/2` makes that true for
  `CI=true` and for self-host (billing off). The e2e stack sets `CI: "true"`
  (`ci/compose.yml`), so the e2e log oracle (`GET /api/logs`) keeps its rows.
  Tests: `logs_persist_policy_test.exs` (describe `client_logs_stop_writes`),
  `runtime_config_test.exs`.
- Setting it needs `bin/engram rpc` in the running task, i.e. ECS exec, which
  only the breakglass profile has. So the override is the **emergency and
  rollback lever** (and what a self-hoster or staging uses), not the planned
  way to turn the move on:
  `bin/engram rpc 'Engram.ServiceConfig.override(:client_logs_stop_writes, true, by: "<operator>")'`;
  `ServiceConfig.clear(:client_logs_stop_writes)` restores the default.

## Post-release plan

1. Release with writes ON (this PR).
2. One Loki check on a sample account that the new lines arrive: a
   `crdt channel joined` or `pullAll` info line and a stacked error line (the
   stack follows the message on new lines), with the query below.
3. Flip the CODE default to stopped in the next release (a small reviewed PR
   changing the default in `Engram.Logs.writes_stopped?/0`), unless an admin
   switch path exists by then. A DB override of `false` then restores writes
   (breakglass).

## Why

2026-11-21 audit: `client_logs` is ~295k rows / 107 MB (85 MB heap, 22 MB
indexes) with 7-day retention, ~41k rows a day, and two accounts hold ~83%
of the rows (looping plugins). The cost was the write load, not the size.
Parity before the flip: 20 sampled accounts (10 busiest, 10 random), warn and
error rows in the DB equalled the Loki entries for every account (gap 0), by
adding each re-emitted line's `repeat` count back.

## Replacing a `client_logs` query with Loki

Every client line is `category=client`. Fields on the line:

- `metadata_user_id`: HMAC-hashed (`Engram.Crypto.HMAC.hash_user_id/1`), so
  find a user's hash from one of their `metadata_conn_id` values (raw), not
  by computing it.
- `metadata_conn_id` (raw), `metadata_device_id` (hashed), `metadata_platform`
  (`desktop`, `mobile`, `web`), `metadata_plugin_version`, `metadata_forced`,
  `metadata_client_severity` (`warn` or `error`; Loki `severity` is `warning`
  for both).
- `metadata_repeat`: identical lines of one batch collapse to one line with
  this count. Entries = lines without it + the sum of it.
- The stack, when the client sent one, follows the message on new lines.

```logql
# warn and error lines of one connection, last day
{service="engram", env="prod"} |= "[client:" | json | metadata_category="client" | severity="warning" | metadata_conn_id="<conn_id>"

# entries per user over 7d (lines with no repeat + repeats)
sum by (metadata_user_id) (count_over_time({service="engram", env="prod"} |= "[client:" | json | metadata_category="client" | severity="warning" | metadata_repeat="" [7d]))
+ sum by (metadata_user_id) (sum_over_time({service="engram", env="prod"} |= "[client:" | json | metadata_category="client" | severity="warning" | metadata_repeat!="" | unwrap metadata_repeat [7d]))
```

Info lines: only the `Engram.Logs.PersistPolicy` allowlist (first-sync
milestones, web deaf-note breadcrumbs) and `diagnostic` lines ship, as
before. Loki retention applies, not the table's 7 days.

## Readers of `client_logs` and what changed

| Reader | On SaaS now |
|---|---|
| `GET /api/logs` | Once writes are stopped: rows older than the switch (up to 7 days), then `[]`. Use Loki (above). CI and self-host unchanged. |
| e2e log oracle and tests (`e2e/helpers/log_oracle.py`, `test_16`, `test_66`, `test_81`) | CI stack, `CI=true`: unchanged. |
| `Engram.Workers.ClientLogsPruner` | Keeps running; nothing new to prune on SaaS. |
| Bastion or `bin/engram rpc` reads | Use Loki. The workspace runbooks that said `client_logs` are updated in the paired workspace docs PR. |
| Alerts (`engram-infra` `web-api-request-failure`) | Read Loki: unchanged. |
| Staging and the local SaaS-shaped dev mode | Both run without `CI=true`, so `client_logs_persist_all` is false and, once writes are stopped, `GET /api/logs` is empty there too. Staging: query staging Loki if it ships there. Local dev has no Loki: read the dev console (the lines are on stdout). Set the override `false` in the dev DB to write rows again. |
