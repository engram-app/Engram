defmodule Engram.Attachments.LocationRlsPlanTest do
  # S6 step 6 reads (Engram#2523) planned as prod runs them: as `engram_app`
  # under FORCE RLS, custom and (named statements) generic plans
  # (`QueryPlan.rls_plans/3`). The by-path lookup in a vault holding a folder
  # moved without a cascade, the relocation probe a write sends there
  # (`Location.stale_rows/4`) and the moved-folder feed's attachment leg must
  # each drive an index, never read the tenant's attachments
  # (docs/context/rls-leakproof-index-quals.md, the notes twin is
  # `Engram.Notes.LocationRlsPlanTest`).
  #
  # 1,000 seeded attachments, every one keyed (as the `attachment_name_key`
  # ledger leaves a vault), with `n_distinct = 40` on the tenant columns so a
  # generic `vault_id = $n` is costed as prod's.
  use Engram.DataCase, async: false

  alias Engram.{Attachments, Notes, Repo, Sync}
  alias Engram.Attachments.Location
  alias Engram.QueryPlan
  alias Engram.QueryRecorder

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    for _ <- 1..1000, do: insert(:attachment, user: user, vault: vault)

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "M/n.md", "content" => "n"}, actor: "api")

    {:ok, _} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => "M/x.png",
        "content_base64" => Base.encode64("bytes")
      })

    cursor = Repo.with_tenant!(user.id, fn -> Engram.Vaults.raw_current_seq(vault.id) end)

    {:ok, {:ok, 1}} =
      Repo.with_tenant(user.id, fn -> Notes.rename_folder_uncascaded(user, vault, "M", "N") end)

    Repo.query!(
      "UPDATE attachments SET name_key = sha512(id::text::bytea) " <>
        "WHERE vault_id = $1 AND name_key IS NULL",
      [Ecto.UUID.dump!(vault.id)]
    )

    Repo.query!("ALTER TABLE attachments ALTER COLUMN user_id SET (n_distinct = 40)")
    Repo.query!("ALTER TABLE attachments ALTER COLUMN vault_id SET (n_distinct = 40)")
    QueryPlan.fresh!("attachments")
    QueryPlan.fresh!("folders")

    on_exit(fn ->
      Repo.query!("ALTER TABLE attachments ALTER COLUMN user_id RESET (n_distinct)")
      Repo.query!("ALTER TABLE attachments ALTER COLUMN vault_id RESET (n_distinct)")
    end)

    assert Location.named?(user.id, vault.id)
    %{user: user, vault: vault, cursor: cursor}
  end

  # `[plans]` for every read of `attachments` `fun` sends, after 7 runs (past
  # the 5 custom plans Postgres tries before a named statement may go
  # generic). The generic plan only for a statement prepared NAMED.
  defp plans(user, fun) do
    Repo.query!("DISCARD PLANS")
    {_, queries} = QueryRecorder.record(fn -> for _ <- 1..7, do: fun.() end)
    me = self()

    reads =
      for %{sql: sql, params: params, pid: ^me} <- queries,
          sql =~ ~r/^\s*(WITH|SELECT)/i,
          sql =~ ~r/FROM "?attachments"?/,
          into: %{},
          do: {sql, params}

    assert reads != %{}, "no read of attachments recorded"

    %{rows: named} =
      Repo.query!("SELECT statement FROM pg_prepared_statements WHERE statement = ANY($1)", [
        Map.keys(reads)
      ])

    named = MapSet.new(List.flatten(named))

    for {sql, params} <- reads do
      p = QueryPlan.rls_plans(user.id, sql, params)
      {sql, if(MapSet.member?(named, sql), do: p, else: Map.delete(p, :generic))}
    end
  end

  @bad ["Seq Scan on attachments", "idx_attachments_user", "attachments_vault_id_index"]

  defp refute_vault_scan!(plans) do
    for {sql, by_mode} <- plans,
        {mode, plan} <- by_mode,
        bad <- @bad,
        do: refute(plan =~ bad, "#{mode} plan reads #{inspect(bad)}:\n#{sql}\n\n#{plan}")
  end

  test "the by-path lookup under a moved folder", %{user: u, vault: v} do
    plans =
      plans(u, fn ->
        assert {:ok, %{path: "N/x.png"}} = Attachments.get_attachment(u, v, "N/x.png")
      end)

    refute_vault_scan!(plans)
    assert Enum.any?(plans, fn {_, p} -> p.custom =~ "attachments_name_key_live" end)
  end

  test "the heal probe a write sends, one batch", %{user: u, vault: v} do
    {:ok, fk} = Engram.Crypto.dek_filter_key(u)
    paths = ["N/x.png", "N/y.png", "M/x.png", "top.png"]

    plans =
      plans(u, fn ->
        assert [{_, "M/x.png", "N/x.png"}] =
                 Repo.with_tenant!(u.id, fn -> Location.stale_rows(u, v.id, fk, paths) end)
      end)

    refute_vault_scan!(plans)
  end

  test "the moved-folder feed's attachment leg", %{user: u, vault: v, cursor: cursor} do
    plans =
      plans(u, fn ->
        assert {:ok, %{changes: [_, _]}} = Attachments.list_moved_changes(u, v, cursor)
      end)

    refute_vault_scan!(plans)
    assert Repo.with_tenant!(u.id, fn -> Sync.feed_head(u, v) end) > cursor
  end
end
