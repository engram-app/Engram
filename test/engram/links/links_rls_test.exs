defmodule Engram.Links.LinksRlsTest do
  @moduledoc """
  Pins `Engram.Links`' public API against an ENFORCED row-level security policy.

  ## What this is about

  `note_links` carries FORCE ROW LEVEL SECURITY, as do the `notes` and
  `attachments` tables these functions join against. Every query in
  `Engram.Links` passes `skip_tenant_check: true`, which suppresses only
  Engram's own guard in `Repo.prepare_query/3` — it sets no tenant in Postgres.

  Unscoped, under any role without SUPERUSER or BYPASSRLS:

    * reads return ZERO ROWS — a note renders with no links and no backlinks,
      and `live_basename_count/3` answers 0 for a basename that is in use
    * `update_all`/`delete_all` are FILTERED by the policy's USING clause and
      report 0 rows affected, with no error
    * only `insert_all` raises (42501) — covered separately in
      `commit_index_rls_test.exs`

  The silent read is the more damaging half, and it is invisible from the
  application's side: the query succeeds.

  ## Why the rest of the suite does not catch this

  `links_test.exs` covers all of these functions' behaviour thoroughly and
  passes — as the SUPERUSER the test database connects as, which bypasses RLS
  even when it is FORCED. Correct behaviour there says nothing about
  enforcement. This file drops to `engram_app` (created by
  `mix engram.prepare_database`, which both the `mix test` alias and CI run;
  no SUPERUSER, no BYPASSRLS) so the policy actually applies.

  ## The tenant-leak trap

  `Engram.Fixtures.insert_note!/3` writes through `Repo.with_tenant/2`, which
  sets `app.current_tenant` with `set_config(..., true)` — SET LOCAL — and
  whose exit path resets only the ROLE, never the tenant. Under the Ecto
  sandbox the whole test runs inside ONE outer transaction, so that tenant
  persists into everything after it.

  `as_prod_role/1` therefore clears the tenant explicitly. Without that line
  the control below sees rows, every assertion in this file holds trivially,
  and the file guards nothing.

  `async: false` because the role change is connection-global.
  """

  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.Links
  alias Engram.Links.NoteLink
  alias Engram.Links.Parser
  alias Engram.Repo

  setup do
    # `user_with_dek_fixture/1`, not `insert(:user)`: `replace_links/4` needs a
    # DEK to encrypt each edge's target text, and a bare factory user has none.
    # `Fixtures.insert_note!/3` would create one as a side effect, but the
    # `user` struct here would still be the stale pre-DEK copy — which fails
    # `replace_links/4` with `{:error, :no_dek}` in setup and takes every test
    # in the file down with it. Same pattern as `links_test.exs`.
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})
    target = Engram.Fixtures.insert_note!(user, vault, %{path: "Target.md"})

    :ok = Links.replace_links(user, vault, source.id, Parser.extract("See [[Target]]."))

    # Force the edge to be BOUND rather than relying on basename-hmac
    # resolution in the fixture path. `backlinks_for_note/2` filters on
    # `target_note_id`, so a dangling edge would make that test vacuous — it
    # would find nothing whether or not RLS was in play.
    {1, _} =
      from(l in NoteLink, where: l.source_note_id == ^source.id)
      |> Repo.update_all([set: [target_note_id: target.id]], skip_tenant_check: true)

    {:ok, user: user, vault: vault, source: source, target: target}
  end

  # Runs `fun` as the non-BYPASSRLS role with NO tenant set — the shape these
  # functions would run in if the app connected as anything but a superuser.
  #
  # Rolls back unconditionally so the SET LOCAL role and tenant are discarded
  # without a trailing RESET ROLE, which would itself fail with 25P02 if the
  # transaction had been aborted by a raise.
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

  # Commit-based variant, for assertions about PERSISTED effect.
  #
  # `as_prod_role/1` rolls back unconditionally, which is right for the read
  # tests — they assert on return values — and mandatory for anything that can
  # raise: an RLS-rejected INSERT aborts the transaction, and a trailing
  # `RESET ROLE` would then fail with 25P02 and mask the original error.
  #
  # But a rollback also discards the write under test, so an assertion that a
  # row is GONE can never pass. Committing is safe on this path specifically
  # because `delete_all`/`update_all` are FILTERED by the policy rather than
  # rejected, so nothing here raises.
  defp as_prod_role_committing(fun) do
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

  describe "Engram.Links under enforced RLS" do
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

    test "links_for_note/2 returns the note's edges", %{user: user, source: source} do
      assert {:returned, [_ | _] = links} =
               as_prod_role(fn -> Links.links_for_note(user, source.id) end),
             "links_for_note returned no edges — the read was filtered by RLS, so the note " <>
               "renders as having no outgoing links at all"

      assert length(links) == 1
    end

    test "backlinks_for_note/2 returns the incoming edge", %{user: user, target: target} do
      assert {:returned, [_ | _]} =
               as_prod_role(fn -> Links.backlinks_for_note(user, target.id) end),
             "backlinks_for_note returned nothing — the read was filtered by RLS, so the " <>
               "backlinks panel renders empty for a note that has one"
    end

    test "live_basename_count/3 counts the live note", %{user: user, vault: vault} do
      assert {:returned, count} =
               as_prod_role(fn -> Links.live_basename_count(user, vault, "target") end)

      assert count >= 1,
             "live_basename_count returned #{inspect(count)} for a basename that is in use — " <>
               "a filtered read here feeds rename-collision decisions"
    end

    test "on_note_soft_deleted/2 actually drops the outgoing edge",
         %{user: user, source: source} do
      # Committing harness, deliberately: this assertion is about the row being
      # gone afterwards, and the rolling-back helper would discard the delete.
      assert :ok =
               as_prod_role_committing(fn -> Links.on_note_soft_deleted(user.id, source.id) end)

      # Read back OUTSIDE the dropped role. This is the assertion that matters:
      # the delete is FILTERED rather than rejected, so an unscoped call returns
      # :ok having removed nothing.
      remaining =
        Repo.one(
          from(l in NoteLink, where: l.source_note_id == ^source.id, select: count(l.id)),
          skip_tenant_check: true
        )

      assert remaining == 0,
             "the outgoing edge survived on_note_soft_deleted/2 — the DELETE matched zero rows " <>
               "under RLS and reported success, so a deleted note keeps its edges"
    end
  end
end
