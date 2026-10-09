# Context Doc: Testing RLS enforcement (nine traps)

_Last verified: 2026-10-03_

## Status

Current. The shared harness is `Engram.RlsCase` (`test/support/rls_case.ex`);
about 25 test files use it. `test/engram/links/links_rls_test.exs` has the
fullest moduledoc.

Read this BEFORE writing a test that claims to prove a query is tenant-scoped.
Every trap below produced a false green for real.

## What This Is

How to write a test that actually proves Postgres Row Level Security is
enforced on a query — and the nine ways such a test passes while proving
nothing. `docs/context/database-schema-rls.md` covers the policies and the
`Repo.with_tenant/2` model; this doc is only about testing them.

## The checklist

A correct RLS test file has all five. Miss one and green is meaningless.

1. `use Engram.DataCase, async: false` — the role change is connection-global.
2. `import Engram.RlsCase` and use `as_prod_role/1` /
   `as_prod_role_committing/1`. They clear the tenant, then drop to
   `engram_app` with `SET LOCAL SESSION AUTHORIZATION` (not `SET ROLE`, trap 6).
3. A **control test** asserting the dropped role sees zero rows.
4. Assertions on **persisted effect** for `update_all`/`delete_all` — "it
   didn't raise" is vacuous there.
5. A rolling-back harness wherever the code can raise; a committing variant
   only for the filtered-write path.

---

## Trap 1 — only INSERT raises

Under a policy used as both `USING` and `WITH CHECK`, the four statement types
fail in three different ways:

| Statement | Unscoped behaviour | Visible to the caller? |
|---|---|---|
| `INSERT` | rejected, SQLSTATE **42501** | yes, it raises |
| `UPDATE` | rows **filtered** by `USING`, reports `{0, nil}` | **no** |
| `DELETE` | rows **filtered** by `USING`, reports `{0, nil}` | **no** |
| `SELECT` | returns **zero rows** | **no** |

Consequence: a test shaped as "assert this raises" is **vacuous** against
`update_all`/`delete_all`. There is no exception to catch. From
`index_cap_rls_test.exs`:

```elixir
  # Only INSERT raises `42501` under a policy used as both USING and WITH
  # CHECK. An UPDATE has its rows FILTERED by the USING clause instead, so an
  # unscoped `update_all` reports `{0, nil}` and the caller returns `:ok`
  # having changed nothing. There is no exception to catch.
  #
  # So these assert the PERSISTED EFFECT, and seed a non-nil value first so the
  # assertion cannot be satisfied by an empty match. A test that merely checked
  # "no error was raised" would pass against the broken code.
```

So: seed a row with a non-nil value, run the function under the dropped role,
read back **outside** the role, assert the row actually changed or vanished.
The seeded precondition is load-bearing — if the column were already `nil` the
assertion would hold no matter what the function did.

```elixir
      # Precondition, not decoration: if these were already nil the assertions
      # below would hold no matter what the function did.
      assert note.embed_hash == "stale-embed"
      assert note.dense_indexed_hash == "stale-dense"

      assert :ok = as_prod_role(fn -> IndexCap.evict_over_cap(user.id) end)

      reloaded = Repo.get!(Note, note.id, skip_tenant_check: true)

      assert is_nil(reloaded.dense_indexed_hash),
             "dense_indexed_hash survived evict_over_cap/1 — the UPDATE was filtered by " <>
               "RLS and reported zero rows, so the user keeps paying for dense vectors"
```

**The silent read is the more damaging half in production**, because the query
*succeeds*: a note renders with no links and no backlinks, an empty vault is
reported for a user who has notes, and `live_basename_count/3` answers 0 for a
basename that is in use. Nothing logs, nothing retries.

## Trap 2: a leaked tenant fakes coverage

A subtransaction's `SET LOCAL` persists into the enclosing transaction once it
commits, and under the sandbox the whole test is one outer transaction. Before
#1761, `with_tenant/2` reset only the role on exit, so one earlier tenant block
(a fixture, or the code's own first write) left `app.current_tenant` set for
every later unscoped statement. A `commit_index/1` RLS test passed while
`Links.replace_links/4` was still unscoped. #1761 now clears the tenant on exit
too (`test/engram/repo/tenant_exit_reset_test.exs`), and the leak was never
sandbox-only: production nests `with_tenant` inside plain transactions too.

What still holds:

- **Every RLS test file needs a CONTROL test** asserting the dropped role sees
  zero rows. Without it, green is ambiguous between "correctly scoped" and
  "the role drop never engaged". See the control test in `links_rls_test.exs`.
- **Give every write on a path its own direct test.** One scoped write proves
  nothing about the next.
- **Do not drive an RLS test through a wrapper that opens its own tenant
  block** (e.g. `index_note/2` via `IndexCap.within_cap?/2`). Run the
  non-writing half as the superuser and only the write under the dropped role.

## Trap 3 — two harnesses are required

**Rolling-back (`as_prod_role/1`), wherever the code under test can raise.**
An RLS-rejected INSERT aborts the transaction; a trailing reset would then fail
with SQLSTATE **25P02** and mask the original error. Rolling back discards the
`SET LOCAL` state anyway. The outcome comes back as `{:returned, v}` or
`{:raised, e}`.

**Committing (`as_prod_role_committing/1`), for persisted-effect assertions.**
A rollback also discards the write under test, so "the row is gone
afterwards" can never pass under it. Safe only on the filtered-write path,
because filtered `update_all`/`delete_all` never raise. Its reset runs on the
success path, never in an `after` (on the raise path it would 25P02 and mask
the error). The reset is mandatory there: these transactions are savepoints
under the sandbox, and `RELEASE SAVEPOINT` would otherwise leak `engram_app`
into later tests.

Do not hand-roll either. Six copies across five files once drifted into three
spellings, one reusing the name `as_prod_role` for the committing variant.

## Trap 4 — why the rest of the suite catches none of this

dev, CI and test all connect as **`engram`**, the cluster bootstrap role:
`rolsuper = true`, `rolbypassrls = true`, so `row_security_active()` is false.
Superusers bypass RLS **even when the table carries `FORCE ROW LEVEL SECURITY`**.

So the existing tests over the same functions — `links_test.exs`,
`indexing_test.exs` — pass, cover the behaviour thoroughly, and prove **nothing
about enforcement**. `indexing_test.exs` already asserts `index_note/2` writes
chunk rows and would fail on exactly this bug; it was green throughout.

An RLS test must therefore drop the role. `engram_app` (no SUPERUSER, no
BYPASSRLS) is created by `mix engram.prepare_database`, which the `mix test`
alias and CI run before migrating.

Three further facts that matter when reasoning about whether enforcement is
actually on:

- **`ENABLE` vs `FORCE` are different.** `ENABLE ROW LEVEL SECURITY` exempts
  the table **owner**; `FORCE ROW LEVEL SECURITY` is what binds the owner too.
  Our tenant tables carry both (see `database-schema-rls.md`). Neither binds a
  superuser or a `BYPASSRLS` role.
- **Role attributes are NOT inherited through role membership.** `BYPASSRLS`
  and `SUPERUSER` apply only to the role you have actually `SET ROLE`d to.
  Granting membership in a bypassing role does not confer the bypass, and
  `engram_app` is `NOINHERIT` besides. (Prod's `engram_admin` still read past
  FORCE RLS through its RDS memberships, mechanism unpinned, #1726. Measure,
  do not reason from attributes.)
- **`skip_tenant_check: true` grants no bypass whatsoever.** It suppresses
  *only* Engram's own application-level guard in `Repo.prepare_query/3`. It sets
  nothing in Postgres, switches no role, and touches no session state. Code
  reading `skip_tenant_check: true` as "this query is exempt from RLS" is the
  root misunderstanding these test files exist to catch.

## Trap 5 — `async: false`

The role drop is **connection-global**. Every RLS test module is
`use Engram.DataCase, async: false`. Under `async: true` the role change is
visible to any other test sharing the connection.

Also, do not reach for `@moduletag :integration` to isolate these. That tag is
excluded unless `INTEGRATION_TESTS=1`, which CI never sets — a tagged file would
guard nothing. It exists for tests needing a local docker container to drive
`pg_dump`; these need only the `engram_app` role.

## Trap 6 — `SET LOCAL ROLE` is un-enforced by the first `with_tenant` beneath the code under test

`SET ROLE` and `SET SESSION AUTHORIZATION` are not interchangeable here, and
picking the first one makes the harness **structurally unable to enforce
anything** against code that calls `Repo.with_tenant/2`.

`test/support/rls_case.ex` dropped the connection with `SET LOCAL ROLE
engram_app` in both helpers. `Repo.with_tenant/2` drops back to `session_user` by running
`set_config('role', 'none', true)` (its own `tenant_exit` in a nested or
sandboxed block; COMMIT does the same reset for a top-level block). Under
`SET ROLE` that is the suite's superuser `engram`, which bypasses RLS even under
`FORCE ROW LEVEL SECURITY` (trap 4). So the **first** `with_tenant` call
anywhere beneath the code under test silently handed the connection back to the
superuser, and every statement after it, including the code under test, ran
unenforced.

Measured: `current_user` was `engram_app` before a real
`Lifecycle.hard_delete/2` call inside the harness and `engram` after it, and
`LifecycleRlsTest` was green against broken code.

The fix is the other primitive. `SET LOCAL SESSION AUTHORIZATION` changes
`session_user` itself, so `ROLE NONE` lands back on `engram_app`:

```elixir
        Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")
```

and the committing variant resets with `RESET SESSION AUTHORIZATION`.
`test/engram/repo/session_role_test.exs` pins the difference against a live
server.

## Trap 7: `hard_delete/2` and the FK topology

Fixed at the source by #1761; kept for the FK facts. Before it, a tenant leaked
from Step 2 (`Indexing.forget_chunk_reuse_for_user/1`) satisfied the `vaults`
policy at the Step 4 commit point, so the bug could not be reproduced through
the real entry point. `LifecycleRlsTest` cleared the tenant through its swapped
storage adapter (a seam that needs no `lib/` change) rather than test a
hand-copied replica.

Why vault-delete ordering is load-bearing (`pg_constraint.confdeltype`):

| FK | Target | On delete |
|---|---|---|
| `notes`/`attachments`/`chunks`.`user_id` | `users` | NO ACTION |
| `notes`/`attachments`/`chunks`.`vault_id` | `vaults` | CASCADE |

Child rows go only as a side effect of the vault delete. If RLS filters that
delete to 0 rows, the `users` delete raises 23503 on `notes_user_id_fkey`.

## Trap 8: a unique-constraint write inside `with_tenant/2` needs `mode: :savepoint`

Not a test trap strictly, but it surfaces while writing these tests. Any
`Repo.insert`/`Repo.update` that can hit a unique constraint **inside**
`Repo.with_tenant/2` must pass `mode: :savepoint`. Without it the constraint
error aborts the transaction, and `with_tenant/2`'s trailing role-reset query
then dies with SQLSTATE **25P02** `in_failed_sql_transaction`. The caller gets
a crash instead of `{:error, changeset}`, so `unique_constraint/3` on the
changeset never gets a chance to turn it into a validation error.

```elixir
    Repo.with_tenant!(user.id, fn -> Repo.insert(changeset, mode: :savepoint) end)
```

Sites: `lib/engram/accounts/export.ex` `insert_pending/1` (a concurrent request
trips the partial unique index), and `lib/engram/workers/account_export.ex`
`save/1` (an Oban retry of a `:failed` export, after the user has requested a
new one, trips `account_exports_one_active_per_user` on the flip to
`:running`). Precedent: `Vaults.create_vault` (`lib/engram/vaults.ex`).

## Trap 9: proving a cross-tenant sweep runs on `Engram.Repo.Maintenance`

A sweep that must see every tenant's rows only works on the maintenance pool.
Run on `Repo` it is filtered to zero rows (trap 1) and reports success. The
test has to make those two outcomes distinguishable.
`test/engram/workers/export_expiry_sweep_maintenance_test.exs` is the worked
example:

1. Start a real maintenance pool:
   `start_supervised!({Engram.Repo.Maintenance, Keyword.merge(Repo.config(), pool: DBConnection.ConnectionPool, pool_size: 1)})`.
2. Set `:maintenance_repo_enabled` (and `on_exit` delete it).
3. Insert fixtures **committed**, via `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`.
   The maintenance pool is a second connection and cannot see sandbox rows.
   Delete them in `on_exit`, since no rollback will.
4. Run the job under `as_prod_role_committing/1`, so the app pool is filtered
   to zero. Only a sweep on the maintenance pool can then change the row.

Mutation-checked: moving the sweep back onto `Repo` fails the test.

**Related: a "must not touch another tenant's row" worker test is vacuous under
`as_prod_role`.** The dropped role filters an unscoped read too, so the test
passes whether or not the worker scopes by owner. Run it as the superuser
instead; `with_tenant/2` drops to `engram_app` by itself, so the scoping under
test is still exercised. See "a job naming the wrong owner touches nothing" in
`test/engram/accounts/export_rls_test.exs`.

---

## The scoping pattern for fixing call sites

When a test above goes red, the fix is a `do_*` delegation wrapper: the public
function becomes a `with_tenant/2` call and the original body moves **verbatim**
into a private `do_*`.

```elixir
  def live_basename_count(user, vault, key) do
    {:ok, result} =
      Repo.with_tenant(user.id, fn -> do_live_basename_count(user, vault, key) end)

    result
  end

  defp do_live_basename_count(user, vault, key) do
    # ...original body, unchanged...
```

**Why this shape:** it only requires editing the `def` line. Long function
bodies stay untouched, so the diff stays reviewable — no re-indentation noise
across hundreds of lines, and a reviewer can see at a glance that the body did
not change. `with_tenant/2` is re-entrant for the same tenant, so private
helpers need no wrapping of their own and a caller that already holds the tenant
(e.g. `RewriteNoteLinks`) pays nothing.

Note the `{:ok, result} = ...; result` unwrap: `with_tenant/2` returns
`{:ok, value}`. Funs passed to it must return **bare** values, not `{:ok, _}` —
see `docs/context/with-tenant-return-wrapping.md`.

**The one real constraint discovered: external I/O must sit OUTSIDE the
`with_tenant` scope**, because `with_tenant/2` opens a transaction and holding
one open across S3 or a job insert is not acceptable. `user_dek_rotation.ex` is
the worked example — scope the read, then leave:

```elixir
    # Tenant scope ends with this read: everything below it is S3 I/O, which
    # has no business inside a transaction.
```

```elixir
    # Cursor only. The per-attachment work below does S3 I/O, which must not
    # run inside a transaction, so each of its DB steps takes its own tenant
    # scope instead of inheriting one from here.
```

Oban inserts likewise stay outside, and for a second reason — `oban_jobs` has no
RLS at all, while `with_tenant/2` would drop the connection to `engram_app`:

```elixir
    # `vaults` is RLS-scoped, so an unscoped read returns [] and silently
    # enqueues nothing. The inserts stay OUTSIDE the tenant scope: `oban_jobs`
    # has no RLS, and `with_tenant/2` drops the connection to `engram_app`.
```

So the pattern for a function that mixes DB writes with external I/O is several
short `with_tenant/2` blocks around the DB steps, not one block wrapping the
whole thing.

## Gotchas

- **A no-op write cannot violate a policy.** `insert_all(_, [])` is a no-op, so
  a fixture that produces no rows makes the test vacuous. Both link tests assert
  their fixture produced rows first: `assert [_ | _] = prepared.links, "fixture
  produced no link rows, so insert_all would be a no-op and prove nothing"`.
- **Guard against the short-circuit branch.** `prepare_index/3` returns
  `{:ok, {:no_chunks, link_rows}}` for an empty or over-cap note and
  `commit_index/1` is never reached, so the test could "pass" having committed
  nothing. `assert %{chunk_rows: [_ | _]} = prepared` before proceeding.
- **A bare factory user has no DEK.** `insert(:user)` has no `encrypted_dek`;
  the first write through `Notes.upsert_note/3` or `Fixtures.insert_note!/3`
  creates one as a side effect, but the `user` struct you are holding is still
  the stale pre-DEK copy. Passing it on fails with `{:error, :no_dek}` in setup
  and takes the whole file down with a failure that looks nothing like RLS. Use
  `Engram.Fixtures.user_with_dek_fixture/1`, or reload with `Repo.get!/2`.
- **A dangling edge makes a backlink test vacuous.** `backlinks_for_note/2`
  filters on `target_note_id`, so force the edge BOUND in setup rather than
  relying on basename-hmac resolution in the fixture path.
- **`Bypass.expect/2` requires at least one matching request**, so it belongs in
  the tests that actually talk to Qdrant. In `setup` it fails the control test,
  which performs no HTTP at all.
- **Read-back assertions need `skip_tenant_check: true`** — they run outside any
  tenant scope, so `prepare_query/3`'s guard would otherwise raise before the
  query ran.

## Failed Approaches / Dead Ends

- **Asserting "it raises" for an unscoped `update_all`/`delete_all`.** Vacuous —
  filtered writes report `{0, nil}` and the caller returns `:ok`. This is
  exactly why both `IndexCap` write sites outlived commit `1f336bfa`, which
  scoped that module's count *reads* and left the writes behind: nothing failed
  loudly.
- **Driving the test through the real entry point** (`index_note/2`). Its
  `IndexCap.within_cap?/2` prelude opens its own tenant block whose exit resets
  the role, so the code under test ran as the superuser again.
- **Trusting one scoped write on a multi-write path.** The sandbox leak-forward
  makes the later writes inherit the earlier tenant. Every write on the path
  needs its own direct test.
- **`@moduletag :integration`.** Never runs in CI; guards nothing.
- **`SET LOCAL ROLE` in the harness.** Reverted to the superuser by the first
  `with_tenant` exit beneath the code under test, so the file enforces nothing
  (trap 6). Use `SET LOCAL SESSION AUTHORIZATION`.
- **Flipping the WHOLE suite to `engram_app` as a CI gate.** Tried 2026-09-17,
  abandoned. 541 failures in 59 files, 82% in `setup`, only 6 behavioural:
  ExMachina's `insert/1` sets no tenant, so it measures fixtures, not code.
  ExMachina's `insert/N` is not overridable and ExUnit has no hook between
  `setup` and the test body. It survives as an opt-in diagnostic:
  `ENGRAM_ENFORCE_RLS=1 mix test <slice>` (`test/support/data_case.ex`), with
  `@moduletag :rls_unsafe` opt-outs. The per-file harness is the real
  mechanism.

## References

- `test/engram/links/links_rls_test.exs` — fullest moduledoc, both harnesses
- `test/engram/indexing/commit_index_rls_test.exs`: trap 2
- `test/engram/indexing/index_cap_rls_test.exs` — filtered-write assertions
- `test/integration/rls_uuid_binding_test.exs` — where the role-drop technique came from
- `lib/engram/repo.ex` — `with_tenant/2`, `prepare_query/3`, `@tenant_tables`
- `lib/engram/release.ex` — `engram_app` role creation
- `lib/engram/crypto/user_dek_rotation.ex` — external I/O outside the tenant scope
- `test/support/rls_case.ex` — both harnesses; moduledoc explains the
  `SESSION AUTHORIZATION` choice
- `test/engram/accounts/lifecycle_rls_test.exs`: traps 6 and 7
- `test/engram/repo/session_role_test.exs` — pins `SET ROLE` vs
  `SESSION AUTHORIZATION`
- `lib/engram/accounts/lifecycle.ex` — `hard_delete/2` steps 0-5; the commit
  point is Step 4
- `lib/engram/indexing.ex` — `forget_chunk_reuse_for_user/1`, the Step 2 tenant
  leak source
- `test/engram/workers/export_expiry_sweep_maintenance_test.exs`: trap 9, the
  maintenance-pool sweep test
- `test/engram/accounts/export_rls_test.exs`: the superuser-run wrong-owner test
- `lib/engram/accounts/export.ex`, `lib/engram/workers/account_export.ex`,
  `lib/engram/vaults.ex`: trap 8 `mode: :savepoint` sites
- `docs/context/database-schema-rls.md` — policies, roles, enforcement layers
- `docs/context/with-tenant-return-wrapping.md` — funs must return bare values
