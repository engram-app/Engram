# Context Doc: Testing RLS enforcement (nine traps)

_Last verified: 2026-09-25_

## Status

Current. Three enforcement test files exist and follow this shape:
`test/engram/links/links_rls_test.exs` (fullest moduledoc, two harnesses),
`test/engram/indexing/commit_index_rls_test.exs`,
`test/engram/indexing/index_cap_rls_test.exs`.

Read this BEFORE writing a test that claims to prove a query is tenant-scoped.
Every trap below produced a false green for real while these files were written.

## What This Is

How to write a test that actually proves Postgres Row Level Security is
enforced on a query — and the nine ways such a test passes while proving
nothing. `docs/context/database-schema-rls.md` covers the policies and the
`Repo.with_tenant/2` model; this doc is only about testing them.

> `database-schema-rls.md`'s "Testing RLS with Ecto.Sandbox" section is the
> naive version. It is not wrong about `prepare_query/3`, but its example
> proves nothing about Postgres: it never drops the superuser role, so RLS is
> not in play, and trap 2 below makes even a role-dropping version leak.

## The checklist

A correct RLS test file has all five. Miss one and green is meaningless.

1. `use Engram.DataCase, async: false` — the role change is connection-global.
2. A harness that clears the tenant **and** drops the role, in that order —
   and the drop must be `SET LOCAL SESSION AUTHORIZATION`, not `SET ROLE`
   (trap 6).
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

## Trap 2 — the sandbox leak-forward (the one that faked coverage)

**This is the important one.** It produced a real false green.

A subtransaction's `SET LOCAL` **persists into the enclosing transaction** once
the subtransaction commits. Under the Ecto sandbox the whole test runs inside
ONE outer transaction, so a single `Repo.with_tenant/2` call anywhere earlier in
a test leaves `app.current_tenant` set for **every later unscoped statement in
that test**. Production has no enclosing transaction: there `with_tenant/2`
opens a real top-level transaction, `SET LOCAL` is discarded at its commit, and
the following statements run with no tenant at all.

Concretely, from `commit_index_rls_test.exs`: a `commit_index/1` RLS test
**passed while `Links.replace_links/4` was still unscoped and broken**, because
`commit_index/1` scoped its own chunk write first and `replace_links/4`
inherited that tenant for free inside the sandbox.

```elixir
    # `Repo.with_tenant/2` sets the tenant with `set_config(..., true)` — SET
    # LOCAL. Under the Ecto sandbox its transaction is a SAVEPOINT nested in
    # this test's outer transaction, and a subtransaction's SET LOCAL PERSISTS
    # to the enclosing transaction once it commits. So every statement
    # `commit_index/1` runs AFTER its own tenant block inherits that tenant for
    # free — including `Links.replace_links/4`.
    #
    # Production has no enclosing transaction. [...]
    #
    # Net effect: scoping one write inside `commit_index/1` makes the test
    # above green while the later writes remain unscoped in prod. Each write on
    # the path therefore needs its own direct test, which is what this one is.
```

What makes the leak possible at all: `Repo.with_tenant/2`'s exit path resets
only the **role**, never the tenant (`lib/engram/repo.ex`):

```elixir
          _ = query!("SELECT set_config('role', 'none', true)", [], source: "tenant_exit")
```

Two mitigations, **both mandatory**:

**(a) Clear the tenant explicitly, before dropping the role.** Any fixture that
writes through `with_tenant/2` — `Engram.Fixtures.insert_note!/3`,
`Notes.upsert_note/3` — has already set one by the time your harness runs.

```elixir
        Repo.query!("SELECT set_config('app.current_tenant', '', true)")
        Repo.query!("SET LOCAL ROLE engram_app")
```

**(b) Every RLS test file needs a CONTROL test.** Without it, green is
ambiguous between "correctly scoped" and "the role drop never engaged".

```elixir
    # CONTROL. Without this a green file is ambiguous between "correctly
    # scoped" and "the role drop never engaged".
    test "control: the dropped role cannot see the seeded edge", %{source: source} do
      outcome =
        as_prod_role(fn ->
          Repo.one(
            from(l in NoteLink, where: l.source_note_id == ^source.id, select: count(l.id)),
            skip_tenant_check: true
          )
        end)

      assert outcome == {:returned, 0},
             """
             Harness is not engaging RLS, so every assertion in this file is meaningless.

               edges visible as engram_app with no tenant: #{inspect(outcome)} (expected {:returned, 0})

             Either SET LOCAL ROLE did not apply, or the tenant was not cleared
             (see the tenant-leak trap in the moduledoc), or the role has BYPASSRLS.
             """
    end
```

A related corollary: **do not drive an RLS test through a wrapper that opens its
own tenant block.** `commit_index_rls_test.exs` cannot go through
`index_note/2`, because that calls `IndexCap.within_cap?/2` first, whose
`with_tenant/2` exit runs `set_config('role', 'none', true)` — and by the same
leak-forward rule that reverts your `engram_app` role to the superuser default
before the code under test ever runs. Split the pipeline instead: run the
non-writing half as the superuser, and only the write under the dropped role.

## Trap 3 — two harnesses are required

**Rolling-back harness — mandatory wherever the code under test can raise.** An
RLS-rejected INSERT aborts the transaction; a trailing `RESET ROLE` then fails
with SQLSTATE **25P02** and masks the original error. Rolling back discards the
`SET LOCAL` role and tenant anyway, so there is nothing to reset. Carry the
outcome out through the rollback value:

```elixir
  defp as_prod_role(fun) do
    {:error, outcome} =
      Repo.transaction(fn ->
        Repo.query!("SELECT set_config('app.current_tenant', '', true)")
        Repo.query!("SET LOCAL ROLE engram_app")

        outcome =
          try do
            {:returned, fun.()}
          rescue
            e -> {:raised, e}
          end

        Repo.rollback(outcome)
      end)

    outcome
  end
```

**Committing variant — for assertions about persisted effect.** A rollback also
discards the write under test, so "the row is gone afterwards" can never pass
under it. Committing is safe **only on the filtered-write path specifically**,
because filtered `update_all`/`delete_all` never raise:

```elixir
  def as_prod_role_committing(fun) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SELECT set_config('app.current_tenant', '', true)")
        Repo.query!("SET LOCAL ROLE engram_app")

        result = fun.()

        # SUCCESS PATH ONLY. Deliberately not an `after`.
        Repo.query!("RESET ROLE")
        result
      end)

    result
  end
```

**`RESET ROLE` goes on the success path, never in an `after`.** This doc showed
the `after` form for months and one test file copied it. On the raise path the
transaction is already aborted, so the reset fails with 25P02 and replaces the
real error with "current transaction is aborted" — the exact masking the
rolling-back variant above exists to avoid. Letting the raise propagate rolls
the transaction back, which discards the `SET LOCAL` state anyway, so nothing
leaks and the original error survives.

**Do not copy either of these.** Both now live in `Engram.RlsCase`
(`test/support/rls_case.ex`) as `as_prod_role/1` and
`as_prod_role_committing/1`; `import Engram.RlsCase` and use them. Six
hand-rolled copies across five files drifted into three spellings, and one of
them reused the name `as_prod_role` for the *committing* variant — same name,
different return type, in a file sitting next to four that meant the other
thing.

On the committing path `RESET ROLE` **is** mandatory rather than tidiness: these
transactions are savepoints under the sandbox, and `RELEASE SAVEPOINT` would
otherwise leak `engram_app` into the outer sandbox transaction and break later
tests.

## Trap 4 — why the rest of the suite catches none of this

dev, CI and test all connect as **`engram`**, the cluster bootstrap role:
`rolsuper = true`, `rolbypassrls = true`, so `row_security_active()` is false.
Superusers bypass RLS **even when the table carries `FORCE ROW LEVEL SECURITY`**.

So the existing tests over the same functions — `links_test.exs`,
`indexing_test.exs` — pass, cover the behaviour thoroughly, and prove **nothing
about enforcement**. `indexing_test.exs` already asserts `index_note/2` writes
chunk rows and would fail on exactly this bug; it was green throughout.

An RLS test must therefore drop the role:

```elixir
        Repo.query!("SET LOCAL ROLE engram_app")
```

`engram_app` is created by `mix engram.prepare_database`, which both the
`mix test` alias (`mix.exs`) and CI run before migrating:

```elixir
      test: [
        "ecto.create --quiet",
        "engram.prepare_database",
        "ecto.migrate --quiet",
        "test"
      ],
```

```sql
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'engram_app') THEN
      CREATE ROLE engram_app NOINHERIT LOGIN;
    END IF;
```

No `SUPERUSER`, no `BYPASSRLS` — both absent by default, which is the whole
point of dropping to it.

Three further facts that matter when reasoning about whether enforcement is
actually on:

- **`ENABLE` vs `FORCE` are different.** `ENABLE ROW LEVEL SECURITY` exempts
  the table **owner**; `FORCE ROW LEVEL SECURITY` is what binds the owner too.
  Our tenant tables carry both (see `database-schema-rls.md`). Neither binds a
  superuser or a `BYPASSRLS` role.
- **Role attributes are NOT inherited through role membership.** `BYPASSRLS`
  and `SUPERUSER` apply only to the role you have actually `SET ROLE`d to.
  Granting membership in a bypassing role does not confer the bypass, and
  `engram_app` is `NOINHERIT` besides.
- **`skip_tenant_check: true` grants no bypass whatsoever.** It suppresses
  *only* Engram's own application-level guard in `Repo.prepare_query/3`. It sets
  nothing in Postgres, switches no role, and touches no session state. Code
  reading `skip_tenant_check: true` as "this query is exempt from RLS" is the
  root misunderstanding these test files exist to catch.

## Trap 5 — `async: false`

`SET LOCAL ROLE` is **connection-global**. Every RLS test module is
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
engram_app` in both helpers. `Repo.with_tenant/2` exits by running
`set_config('role', 'none', true)`, which reverts to `session_user`. Under
`SET ROLE` that is the suite's superuser `engram`, which bypasses RLS even under
`FORCE ROW LEVEL SECURITY` (trap 4). So the **first** `with_tenant` call
anywhere beneath the code under test silently handed the connection back to the
superuser, and every statement after it, including the code under test, ran
unenforced.

Measured, not theorised: a probe printing `current_user` before and after a real
`Engram.Accounts.Lifecycle.hard_delete/2` call inside the harness showed
`current_user="engram_app"` before and `current_user="engram"` after.
`Engram.Accounts.LifecycleRlsTest`
(`test/engram/accounts/lifecycle_rls_test.exs`) was passing green against
genuinely broken code because of this.

The fix is the other primitive. `SET LOCAL SESSION AUTHORIZATION` changes
`session_user` itself, so `ROLE NONE` lands back on `engram_app`:

```elixir
        Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")
```

and on the committing variant's success path the reset changes to match:

```elixir
        # SUCCESS PATH ONLY. Deliberately not an `after` (trap 3).
        Repo.query!("RESET SESSION AUTHORIZATION")
```

**The code blocks in traps 2, 3 and 4 above still show the superseded
`SET LOCAL ROLE` spelling.** Do not copy them; `import Engram.RlsCase` and use
`as_prod_role/1` or `as_prod_role_committing/1`, which now carry the correct
form.

What makes this the most embarrassing entry in the file: `Engram.Repo.SessionRoleTest`
already pinned this exact Postgres difference against a live server. The harness
simply was not using the primitive that test proved. (That test currently lives
only on branch `feat/rls-enforced-ci`, at `test/engram/repo/session_role_test.exs`;
it is not on `main`, so grepping this worktree for it finds only the reference in
`rls_case.ex`.)

## Trap 7 — a leaked tenant can make the bug UNREPRODUCIBLE through its real entry point

This is a distinct and worse shape of trap 2. There, a leaked tenant makes a
later **unscoped** statement look scoped. Here it goes further: the leak makes
the bug impossible to trigger through the function's real entry point at all.

After fixing trap 6 so the role genuinely survived, `hard_delete/2` **still**
returned `:ok` and still deleted every row. The probe showed why:
`app.current_tenant` was the user's own id at the commit point (Step 4), leaked
forward from a `Repo.with_tenant/2` call in an **earlier step of the same
function** — Step 2, `drop_qdrant_for_user/1`. That leaked tenant *satisfies*
the `vaults` policy, so the vault delete legitimately succeeded. Nothing was
broken about the test's role handling; the code under test was simply handed a
valid tenant by its own earlier step.

> The leaking call verified in this worktree is
> `Engram.Indexing.forget_chunk_reuse_for_user/1`
> (`lib/engram/indexing.ex:402`), which `drop_qdrant_for_user/1` calls
> unconditionally before touching Qdrant. `Vector.Qdrant.delete_by_user/2`
> itself is pure HTTP and opens no transaction.

In production there is no enclosing transaction, so that `SET LOCAL` dies with
its own transaction and the commit point runs with an **empty** tenant. Probing
that production condition directly (`current_user=engram_app`, tenant `''`):

| Probe | Result |
|---|---|
| `row_security_active('vaults')` | `true` |
| `delete_all` on `vaults` | **0 rows** (filtered, per trap 1) |
| subsequent `users` delete | raises **23503** `foreign_key_violation` on `notes_user_id_fkey` |

**Consequence: when an earlier step in the same call chain leaks a tenant, you
cannot reproduce the bug by calling the real entry point at all.** Clearing the
tenant in the harness does not help either, because the leaking step runs after
the harness and re-sets it.

The workaround was to clear the tenant through an **existing seam that runs
between the leaking step and the commit point**. Step 3's `wipe_storage_prefix/2`
goes through `Storage.adapter()`, which this test already swaps, so a test-only
adapter clears the tenant and delegates:

```elixir
defmodule Engram.Accounts.LifecycleRlsTest.TenantClearingStorage do
  def delete_prefix(prefix) do
    Repo.query!("SELECT set_config('app.current_tenant', '', true)")
    InMemory.delete_prefix(prefix)
  end
end
```

That places the tenant exactly where production has it at the commit point:
empty. **Requiring no change to `lib/` code is what makes this acceptable.** The
alternative, testing a hand-copied replica of the commit point, would not have
been testing the real code.

The FK topology is what makes the vault-delete ordering load-bearing, and it is
confirmed against the test database (`pg_constraint.confdeltype`):

| FK | Target | `confdeltype` | Meaning |
|---|---|---|---|
| `notes.user_id` | `users` | `a` | NO ACTION |
| `attachments.user_id` | `users` | `a` | NO ACTION |
| `chunks.user_id` | `users` | `a` | NO ACTION |
| `notes.vault_id` | `vaults` | `c` | CASCADE |
| `attachments.vault_id` | `vaults` | `c` | CASCADE |
| `chunks.vault_id` | `vaults` | `c` | CASCADE |

So the child rows are cleared only as a side effect of the **vault** delete. If
RLS filters that delete to zero rows, the `users` delete that follows has no
route to succeed: it hits `notes_user_id_fkey` and raises. That raise is the
production symptom the green test was hiding.

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
(e.g. `BackfillNoteLinks`) pays nothing.

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
- **`psql` is NOT on PATH on this machine.** To introspect the test database
  (FK topology, `row_security_active`, role attributes), go through the
  container: `docker exec backend-postgres-1 psql -U engram -d engram_test6 ...`.
  The other container, `engram-dev-postgres`, does not have the partitioned test
  databases.

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
- **Testing a hand-copied replica of the commit point.** Considered for trap 7
  and rejected: it would not have been testing the real code. Clearing the
  leaked tenant through a seam the test already controls (the swapped storage
  adapter) keeps the real entry point under test and needs no change to `lib/`.
- **Flipping the WHOLE suite to `engram_app` as a CI gate.** Tried 2026-09-17
  and abandoned the same day. The mechanism works — `SET LOCAL SESSION
  AUTHORIZATION engram_app` in `DataCase.setup_sandbox`, gated on
  `ENGRAM_ENFORCE_RLS=1`, with `@moduletag :rls_unsafe` opt-outs. The
  measurement is the problem.

  Measured across the suite: **541 failures in 59 files, 441 of them (82%)
  originating in `setup`**. By reason: 588 × `new row violates row-level
  security policy`, 5 × `permission denied for schema public` (migration tests
  doing DDL), and **6** behavioural assertion failures in total.

  Cause: ExMachina's `insert/1` sets no tenant, so every tenant-owned fixture
  is rejected before the code under test runs. The job therefore measures
  "fixtures do not scope their inserts", not "production code does not scope
  its queries" — a ~2% signal-to-noise ratio, and a `:rls_unsafe` list of 59
  files would leave a gate asserting almost nothing.

  Two exits are closed, so do not go looking for them. ExMachina generates
  `insert/N` through its Strategy system (`strategy.ex`: `def
  unquote(function_name)` dispatching via `apply/3` to
  `ExMachina.EctoStrategy.handle_insert/2`) — a module we do not own, and there
  is no `defoverridable` for it, only for the deprecated `create/1,2`. And
  ExUnit has no hook between a module's `setup` blocks and the test body, so
  you cannot let fixtures run as superuser and enforce only for the body.

  What survives, and is worth keeping: the flag as an **opt-in diagnostic**
  (`ENGRAM_ENFORCE_RLS=1 mix test <slice>`, then triage by whether the trace
  contains `__ex_unit_setup_`), and `Engram.Repo.SessionRoleTest`, which pins
  the role primitives — notably that `SET ROLE` is NOT usable here, because
  `with_tenant/2`'s exit runs `set_config('role','none',true)` and reverts to
  `session_user`, handing the connection back to the superuser mid-test.

  The per-file harness (`Engram.RlsCase`) remains the real mechanism. One bug,
  one targeted test.

## References

- `test/engram/links/links_rls_test.exs` — fullest moduledoc, both harnesses
- `test/engram/indexing/commit_index_rls_test.exs` — the leak-forward false green
- `test/engram/indexing/index_cap_rls_test.exs` — filtered-write assertions
- `test/integration/rls_uuid_binding_test.exs` — where the role-drop technique came from
- `lib/engram/repo.ex` — `with_tenant/2`, `prepare_query/3`, `@tenant_tables`
- `lib/engram/release.ex` — `engram_app` role creation
- `lib/engram/crypto/user_dek_rotation.ex` — external I/O outside the tenant scope
- `test/support/rls_case.ex` — both harnesses; moduledoc explains the
  `SESSION AUTHORIZATION` choice
- `test/engram/accounts/lifecycle_rls_test.exs` — traps 6 and 7; the
  tenant-clearing storage adapter
- `test/engram/repo/session_role_test.exs` — pins `SET ROLE` vs
  `SESSION AUTHORIZATION` (branch `feat/rls-enforced-ci` only, not on `main`)
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
