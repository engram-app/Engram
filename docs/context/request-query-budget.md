# Request query budget and Engram.Cache

_Last verified: 2026-10-09 (branch `perf/mcp-write-query-count`)_

Every hot request path has a pinned maximum number of Ecto queries, asserted by
`test/engram/query_budget_test.exs`. The point is not the number: each DB round
trip is a pooled connection held for its RTT, and the repeated preamble
(user, API key, subscription, vault list, rotation lock, tenant enter/exit)
dominated every request. This doc records what was cut, the rules the cuts
depend on, and what is left.

## Before and after

"Before" is the Task 1 pin (measured on the branch base, warm caches).
"After" is the current `@budgets` value.

| Path | Before | After |
|---|---|---|
| mcp get_notes | 23 | 4 |
| mcp write_note update | 46 | 14 |
| mcp append_to_note | 62 | 14 |
| mcp edit_note | 57 | 14 |
| mcp delete_note | 39 | 12 |
| GET sync/manifest | 28 | 6 |
| GET notes/*path | 28 | 5 |
| POST notes update | 51 | 15 |
| POST notes create | 56 | 19 |
| POST notes/append | 62 | 15 |
| POST notes/rename | 62 | 39 |
| DELETE notes/*path | 34 | 12 |
| GET /api/bootstrap (warm) | 44 | 3 |
| GET /api/bootstrap cold | n/a (44 was the warm pin) | 21 |
| GET folders | 27 | 5 |
| GET tags | 22 | 4 |
| CRDT keystroke (delta) | 47 (crdt_msg update, included a checkpoint tick) | 4 |
| CRDT checkpoint tick | in the 47 above | 13 |
| CRDT crdt_doc_update idle | 55 | 22 |
| CRDT room open | not pinned (25 measured mid-branch) | 13 |

Bootstrap cold is 21 because 10 of them are the auth plug's own cache misses
(API key lookup alone is 5); warm is 3 because the controller's one tenant
block (begin, enter, commit) opens even when every loader hits.

## Engram.Cache

`Engram.Cache` replaces the per-module `NodeLocalEts` macro and the
`:version_evict_all` trick. One read-through API over node-local ETS:

    Engram.Cache.fetch(:cache_name, key, fn -> load_from_db() end)

- **Registry.** Every cache is declared once in `Engram.Cache.Registry`
  (`ttl`, `cache_nil`, `evict_match`, `pg_channel`, `pg_clear_channel`).
  `Engram.Cache.Server` creates one ETS table per entry.
- **TTL is a backstop.** Freshness comes from eviction; the TTL (30 to 60 s for
  auth data) bounds the damage if an eviction is lost.
- **Trigger NOTIFY eviction.** AFTER-write triggers `pg_notify` the key to
  evict (`users_changed`, `subscriptions_changed`, `api_keys_changed`,
  `api_key_vaults_changed`, `vaults_changed`, `user_limit_overrides_changed`,
  and `note_counts_changed` from migration `20261009130000`, fired by notes and
  attachments writes). Triggers cover raw SQL (support runbooks, e2e helpers),
  which app-level `evict` calls cannot.
  `vaults_changed` is silent on `change_seq` / `updated_at`-only updates and
  `api_keys_changed` on `last_used`-only updates, or every write would evict.
- **Cluster eviction.** App-level `evict/2` and `evict_all/1` also broadcast
  through `Engram.Cluster.CacheSync` (PubSub), so peers drop the key too. The
  local node is evicted directly, not by echo.
- **Listener re-LISTEN.** `Engram.Cache.Listener` owns the LISTEN connection.
  NOTIFYs sent while it was down are lost, so on every (re)connect it
  re-LISTENs and clears every cache that has a channel.
- **Pending-marker guard.** A miss parks a pending marker under the key before
  running the loader; the loaded value is stored only if the marker is still
  there (`:ets.select_replace/2`). An eviction that lands while the loader
  runs deletes the marker, so a value read just before the eviction is returned
  to that caller but never stored. Without it, a revoked API key read just
  before its NOTIFY stayed valid for the whole TTL. There is no single-flight:
  concurrent misses each run the loader.
- **Stored after commit.** A miss inside a tenant transaction stores its value
  through `Repo.after_commit/1`: the loader can see the transaction's own
  uncommitted rows, and a rollback must cache nothing. Cost: a key read twice
  in one cold transaction loads twice (bootstrap cold's vault list).
- **RLS data is cached only when keyed by owner.** The loader runs in the
  caller's process, under the caller's tenant, so the cache never widens what a
  query sees. Never key a tenant-scoped value by something other than its
  owner (`user_id`, or `{user_id, x}` with `evict_match: :first_elem`).
- `Engram.Crypto.DekCache` keeps its own owner-routed implementation
  (`:protected` writes for key material) and does not use the registry.

### Add a cache in 3 steps

1. Add an entry to `@base` in `Engram.Cache.Registry` (name, ttl, `cache_nil`,
   `evict_match`, `pg_channel`).
2. If the source table can be written by anything but one chokepoint, add an
   AFTER-write trigger that `pg_notify`s the key on the channel (migration;
   `CREATE OR REPLACE TRIGGER`, and `SET search_path = ''` on the function).
   Otherwise call `Engram.Cache.evict/2` from the writer, inside
   `Repo.after_commit/1` when it runs in a tenant transaction.
3. Read through `Engram.Cache.fetch/3`; add a test that writes, evicts, and
   re-reads. ExUnit sandbox transactions roll back, so triggers never fire in
   tests: evict explicitly after inserting rows the cache may already hold.

## Repo.with_tenant cost

- A top-level `with_tenant` is **3 round trips**: BEGIN, `tenant_enter`
  (tenant and role drop in one `set_config` SELECT), COMMIT. Both settings are
  `SET LOCAL`, so COMMIT or ROLLBACK resets them and the pooled connection
  returns clean. There is no `tenant_exit` at top level.
- Nested in a plain `Repo.transaction`/savepoint it keeps `tenant_exit` (2
  round trips, no BEGIN/COMMIT), because the outer transaction carries on after
  the block and must not keep the tenant (#1761).
- Same-tenant re-entry runs `fun` directly: no extra statements.
- In the SQL sandbox the exit is emitted as `tenant_exit_sandbox` (the sandbox
  owns the outer transaction, so the commit reset never happens). The budget
  test excludes that source so counts match prod.
- **Fail-closed pool check.** The reset is skipped only when the pool is
  `DBConnection.ConnectionPool` (ecto_sql's default); any other or unknown pool
  keeps `tenant_exit`.
- **DEFERRABLE caveat.** A deferred constraint or deferred trigger fires at
  COMMIT, where the connection is still `engram_app` with the tenant set in
  prod but already reset in the sandbox. There are none today; adding one means
  the suite cannot see a difference. Comment at `Repo.tenant_transaction`.

## Repo.after_commit rules

- `Repo.after_commit/1` queues `fun` until the OUTERMOST `with_tenant`
  commits; a rollback or raise drops the queue. Use it for anything another
  process observes: broadcasts, room pushes, cache evictions.
- A raise in a callback is logged and the rest still run (the write is
  durable).
- A plain `Repo.transaction` does not own the queue, so `with_tenant` legs
  nested in one run their callbacks when each leg returns, before the real
  commit. Compose legs with `Repo.transaction_after_commit/1` (Folders ops,
  `batch_delete_folders`).
- **No external I/O inside a tenant transaction** (Voyage, Qdrant, KMS, HTTP).
  The transaction holds a pooled connection. Resolve it before opening the
  transaction (create_note resolves folder placement first; the DEK is
  provisioned before the request transaction opens).
- **Oban inserts run inline in the transaction.** `engram_app` holds the
  `oban_jobs` grant, so enqueues are atomic with the write; there is no
  after-tenant enqueue hook.
- **Never `Repo.rollback` inside a nested `with_tenant`.** Re-entry and a
  nested plain transaction open no savepoint, so the rollback unwinds the
  OUTERMOST transaction (a whole MCP tool call). Return `{:error, _}` and do
  not write before deciding to refuse.

## CRDT path

- A keystroke (`crdt_msg` update) appends to the tail with **one CTE
  statement** in one tenant txn (4 queries).
- **The ack follows the durable append.** The channel waits on the room for
  the append (5 s timeout) before replying; a crash can no longer lose an
  acked update. Deliberately not coalesced: batching appends would widen the
  window an acked update is only in memory.
- **Failure flag.** If an append fails, the room's failure flag stays set,
  and every ack errors until a checkpoint of that room commits; the client
  retries.
- The room prunes the tail ids it holds at checkpoint (`forget_tail_ids`), so
  the tail compacts on short-lived rooms too.
- Bind reads snapshot and tail in ONE statement; no echo of the snapshot is
  appended on room start, so opening a note no longer pushes to every device.
- A checkpoint tick is one txn plus one dispatcher job (one job per
  checkpoint fans out the embed, link and revision jobs), after one read of
  the rotation lock.
- **Rotation gates on room, socket and worker writes read the lock fresh**
  (`RotationGate.check/1`, one query): the `:user` cache learns of a lock
  taken on another node only when its eviction lands, and an old-DEK write
  after the sweep is unreadable forever (#1341). REST and MCP writes get the
  same read from `RotationLockCheck`.
- Deleting a note, or a folder cascade, terminates its rooms after commit.

## Accepted rulings

- **`get_notes` holds a pooled connection while decrypting** (NIF, about 1 ms
  per note; pool is 225). Accepted.
- **No request-level transaction for REST.** `json/2` sends the response
  inside the action, so a wrapping transaction would answer the client before
  commit. REST gets one transaction per context call, with the cached preamble
  doing most of the work. MCP tool calls are one transaction.
- **A post-commit decrypt of the response links was tried and reverted**: a
  raise would leave a durable write behind a 500 and a retried append would
  double it. Decrypt stays in the write transaction (CPU only).
- **No batch decrypt NIF.** Built and measured: a dirty-scheduler batch was
  7 to 40% slower than per-item opens. See `native-nifs.md`, "No batch
  decrypt".
- Unlisted but binding: `EmbedNote` clamps from the job Oban's unique check
  returns, and OriginStats is an ETS counter flushed by a timer (a test-env
  flag skips the terminate flush).

## The budget test

`mix test test/engram/query_budget_test.exs` (async: false; the telemetry
handler is global). Each case warms the path once, records with
`Engram.QueryRecorder`, then asserts the call succeeded and
`count == @budgets[path]` (exact, so a regression AND an unrecorded
improvement both fail). `tenant_exit_sandbox` rows are excluded.

- **Reading a failure.** The message prints the budget, the actual count and
  every query in order (source, then SQL). Compare against the numbered
  comments next to the budget: each kept query above target carries a one-line
  reason. The new query is the first line not on that list.
- **Warm vs cold.** All budgets are warm (caches primed by the warm-up call)
  except `GET /api/bootstrap cold`, which first clears every cache with a TTL
  of 60 s or less (the long-TTL DEK, plan, entitlement caches stay warm).
  Anything that counts queries must set cache state explicitly (clear then
  warm), and must be `async: false` if an async test can wipe shared tables.
- **Lowering a budget.** Remove a query, run the file (it fails with the new,
  lower count), set the number, and update the comment. Budgets only go down;
  raising one needs a stated reason in the comment, which is the review
  prompt.
- The CRDT checkpoint tick is driven by hand (`send(timer, :tick)`) so the
  CRDT counts are exact, not ceilings.

## Known limits

- **`first_elem` eviction scans the table.** `:note_counts` and
  `:billing_override` evict `{user_id, _}` keys with `ets:match_delete`, a
  full scan in `Cache.Server`, once per note create/delete/rename on every
  node. Negligible at today's user count; a per-user index table or a
  user-keyed map value fixes it.
- **Oban unique locks last until the request commits.** `insert_unique` takes
  `pg_try_advisory_xact_lock`, held to the outer commit. A dispatcher that
  collides with an open REST/MCP txn gets `conflict?: true` and is not
  retried; if that txn then rolls back, neither job exists until the
  reconcile and hourly sweeps.
- **MCP resources are unbudgeted.** `resources/read` (3 txn trips plus the
  read) and `resources/list` (3 per vault it spills into) have no case in the
  budget test (see next targets).
- **A skipped checkpoint after an append failure is not retried.** The room
  refuses acks until a checkpoint commits; if the prompt tick and the settle
  tick both skip (rotation, stale snapshot, legacy row needing a rebind), an
  idle note waits for its next edit or for room exit, which checkpoints.

## Next targets

- **MCP resources budget**: add `resources/read` and `resources/list` cases
  to the budget test before cutting them.

- **Auth plug cold misses**: the API key lookup is 5 queries (BEGIN, lookup
  role, key row with its scope, role reset, COMMIT); 10 of bootstrap cold's 21.
- **Rename (39)**: claim validation txn, index room fold, rename txn,
  post-commit jobs, idle-room fanout and links txn are separate transactions.
- **Delete's two job inserts**: one `insert_all` instead of two inserts and two
  pg_notify.
- **Warm bootstrap (3)**: open the tenant transaction lazily, only on the first
  loader miss. Skipped for now: about 3 ms on a once-per-page call, for cache
  probe complexity.
