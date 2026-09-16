defmodule Engram.Indexing.IndexCapRlsTest do
  @moduledoc """
  Regression test for `skip_tenant_check: true` reads against the `notes`
  table with no `app.current_tenant` set.

  `skip_tenant_check: true` suppresses Engram's APPLICATION-level guard in
  `Repo.prepare_query/3` and nothing else. It does not set
  `app.current_tenant`, does not switch role, and does not touch Postgres.
  `notes` carries `ENABLE` + `FORCE ROW LEVEL SECURITY` with a policy of
  `USING (user_id::text = (SELECT current_setting('app.current_tenant', true)))`,
  so with no tenant set the policy compares against NULL and filters every
  row. The query succeeds, returns zero rows, and the caller reports an empty
  vault for a user who has notes.

  ## Why these tests drop the database role

  The test and CI databases connect as `engram`, the cluster bootstrap user,
  which is a SUPERUSER — and superusers bypass RLS even when it is FORCED. A
  plain value assertion therefore passes against the broken code, which is
  exactly why this class of bug reached production. `SET LOCAL ROLE engram_app`
  drops to the role prod actually runs as (created by `mix engram.prepare_database`,
  which the `mix test` alias and CI both run before migrating, and which has
  neither SUPERUSER nor BYPASSRLS). RLS then genuinely applies.

  Technique borrowed from `test/integration/rls_uuid_binding_test.exs`, with
  two deliberate differences:

    * No `@moduletag :integration`. That tag is excluded unless
      `INTEGRATION_TESTS=1`, which CI never sets, so a tagged test would never
      guard anything. The tag exists for tests needing a local docker
      container to drive `pg_dump`; this file needs only the `engram_app` role.
    * `async: false`, because the role change is connection-global.

  `RESET ROLE` is mandatory, not tidiness: under the Ecto sandbox these
  transactions are savepoints, and `RELEASE SAVEPOINT` would otherwise leak
  `engram_app` into the outer sandbox transaction and break later tests. See
  the comment in `Engram.Repo.with_tenant/2`.
  """

  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.Indexing.IndexCap
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.UsageMeters

  # Runs `fun` as the non-BYPASSRLS role with NO tenant configured — the exact
  # shape of a prod request reaching these code paths.
  #
  # The tenant clear is load-bearing, not hygiene. Several tests below make a
  # superuser "sanity" call first, and those go through `Repo.with_tenant/2`,
  # whose `set_config(..., true)` is a SET LOCAL that PERSISTS into the
  # enclosing sandbox transaction once its savepoint commits — `with_tenant`'s
  # exit resets only the ROLE, never the tenant. Without this line the role
  # drop below re-engages RLS while the policy compares against a MATCHING
  # tenant, so three of the tests in this file passed no matter what the code
  # did. See the leak-forward trap in
  # `docs/context/rls-enforcement-testing-traps.md`.
  defp as_prod_role(fun) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SELECT set_config('app.current_tenant', '', true)")
        Repo.query!("SET LOCAL ROLE engram_app")

        try do
          fun.()
        after
          Repo.query!("RESET ROLE")
        end
      end)

    result
  end

  defp capped_user_with_notes(cap) do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "indexed_notes_cap", value: %{"v" => cap})
    vault = insert(:vault, user: user)

    older =
      insert(:note, user: user, vault: vault, created_at: ~U[2026-01-01 00:00:00Z])

    newer =
      insert(:note, user: user, vault: vault, created_at: ~U[2026-01-02 00:00:00Z])

    %{user: user, older: older, newer: newer}
  end

  # CONTROL. Without this the file cannot tell "correctly scoped" from "the
  # role drop never engaged", which is exactly how the read tests below came to
  # be vacuous without anyone noticing.
  describe "harness" do
    test "control: the dropped role with no tenant sees zero notes" do
      %{user: user} = capped_user_with_notes(2_000)

      seen =
        as_prod_role(fn ->
          Repo.one(
            from(n in Note, where: n.user_id == ^user.id, select: count(n.id)),
            skip_tenant_check: true
          )
        end)

      assert seen == 0,
             """
             Harness is not engaging RLS, so every assertion in this file is meaningless.

               notes visible as engram_app with no tenant: #{inspect(seen)} (expected 0)

             Either SET LOCAL ROLE did not apply, or the tenant was not cleared
             (a superuser `with_tenant` call earlier in the test leaks its
             tenant forward), or the role has BYPASSRLS.
             """
    end
  end

  describe "counts/1 under FORCE RLS" do
    test "reports the real note total when no tenant is set" do
      %{user: user} = capped_user_with_notes(2_000)

      # Sanity: as the superuser the rows are plainly there, so a zero below
      # is RLS filtering rather than a broken fixture.
      assert %{total: 2} = IndexCap.counts(user)

      assert %{indexed: 2, total: 2} = as_prod_role(fn -> IndexCap.counts(user) end)
    end
  end

  describe "within_cap?/2 under FORCE RLS" do
    test "counts older notes, so a note past the cap is excluded" do
      %{user: user, newer: newer} = capped_user_with_notes(1)

      # With cap=1 the newer note has exactly one older sibling, so it sits
      # OUTSIDE the cap. If the rank query sees zero rows it computes
      # `0 < 1` and wrongly admits the note — a permissive failure that
      # silently over-indexes on the hot path.
      refute IndexCap.within_cap?(newer, user)

      refute as_prod_role(fn -> IndexCap.within_cap?(newer, user) end)
    end
  end

  # The two tests below cover WRITES, and they are shaped differently from the
  # read tests above for a reason worth stating.
  #
  # Only INSERT raises `42501` under a policy used as both USING and WITH
  # CHECK. An UPDATE has its rows FILTERED by the USING clause instead, so an
  # unscoped `update_all` reports `{0, nil}` and the caller returns `:ok`
  # having changed nothing. There is no exception to catch.
  #
  # So these assert the PERSISTED EFFECT, and seed a non-nil value first so the
  # assertion cannot be satisfied by an empty match. A test that merely checked
  # "no error was raised" would pass against the broken code.
  #
  # This is also why both sites outlived 1f336bfa, which scoped the count reads
  # in this module and left these two writes behind: nothing failed loudly.
  describe "revoke_dense_index/1 under FORCE RLS" do
    test "clears both hashes instead of silently matching zero rows" do
      user = insert(:user)
      vault = insert(:vault, user: user)

      note =
        insert(:note,
          user: user,
          vault: vault,
          embed_hash: "stale-embed",
          dense_indexed_hash: "stale-dense"
        )

      # Precondition, not decoration: if these were already nil the assertions
      # below would hold no matter what the function did.
      assert note.embed_hash == "stale-embed"
      assert note.dense_indexed_hash == "stale-dense"

      assert :ok = as_prod_role(fn -> IndexCap.revoke_dense_index(user.id) end)

      reloaded = Repo.get!(Note, note.id, skip_tenant_check: true)

      assert is_nil(reloaded.dense_indexed_hash),
             "dense_indexed_hash survived revoke_dense_index/1 — the UPDATE was filtered by " <>
               "RLS and reported zero rows, so the user keeps paying for dense vectors"

      assert is_nil(reloaded.embed_hash),
             "embed_hash survived, so the note never re-enters the reconcile query and the " <>
               "dense points are never replaced"
    end
  end

  describe "backfill_freed_slots/1 under FORCE RLS" do
    test "frees the slot instead of silently matching zero rows" do
      user = insert(:user)
      insert(:user_limit_override, user: user, key: "indexed_notes_cap", value: %{"v" => 2_000})
      vault = insert(:vault, user: user)

      note = insert(:note, user: user, vault: vault, embed_hash: "stale-embed")

      assert note.embed_hash == "stale-embed"

      assert :ok = as_prod_role(fn -> IndexCap.backfill_freed_slots(user.id) end)

      reloaded = Repo.get!(Note, note.id, skip_tenant_check: true)

      assert is_nil(reloaded.embed_hash),
             "embed_hash survived backfill_freed_slots/1 — the UPDATE matched zero rows under " <>
               "RLS, so a user who deleted notes to make room stays stuck at their cap with " <>
               "no error anywhere"
    end
  end

  describe "recount_notes!/1 under FORCE RLS" do
    test "recomputes the true count rather than writing a zero" do
      %{user: user} = capped_user_with_notes(2_000)

      assert UsageMeters.recount_notes!(user.id) == 2

      # This one WRITES what it reads, so a filtered read does not merely
      # report wrong — it persists a 0 over a correct counter.
      assert as_prod_role(fn -> UsageMeters.recount_notes!(user.id) end) == 2
      assert UsageMeters.notes_count(user.id) == 2
    end
  end
end
