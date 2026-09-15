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

  alias Engram.Indexing.IndexCap
  alias Engram.Repo
  alias Engram.UsageMeters

  # Runs `fun` as the non-BYPASSRLS role with NO tenant configured — the exact
  # shape of a prod request reaching these code paths.
  defp as_prod_role(fun) do
    {:ok, result} =
      Repo.transaction(fn ->
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
