defmodule Engram.Indexing.NoteCountsMaintenanceTest do
  @moduledoc """
  Review L5: the chunk counters and the `NoteIndexState` backfill through
  the maintenance pool, connected as the real `engram_maintenance` role
  (no SUPERUSER, no BYPASSRLS: only its `maintenance_all` policies let it
  see any row). A missing grant or policy on `note_index_state` turns
  these red. Fixtures are COMMITTED (the pool is a second connection) and
  removed on exit.
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.DataMigrations.NoteIndexState, as: Ledger
  alias Engram.Indexing.ChunkRows
  alias Engram.Notes
  alias Engram.Notes.{Chunk, NoteIndexState}
  alias Engram.Repo
  alias Engram.Repo.Maintenance

  setup do
    config =
      Keyword.merge(Repo.config(),
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        after_connect: {Postgrex, :query!, ["SET SESSION AUTHORIZATION engram_maintenance", []]}
      )

    start_supervised!({Maintenance, config})
    Application.put_env(:engram, :maintenance_repo_enabled, true)
    on_exit(fn -> Application.delete_env(:engram, :maintenance_repo_enabled) end)

    {user, vault, note} =
      Sandbox.unboxed_run(Repo, fn ->
        user = insert(:user)
        {:ok, user} = Engram.Crypto.ensure_user_dek(user)
        vault = insert(:vault, user: user)

        {:ok, note} =
          Notes.upsert_note(user, vault, %{"path" => "A.md", "content" => "# A\n\nbody"},
            actor: "api"
          )

        rows =
          for pos <- 0..2,
              do: %{
                note_id: note.id,
                user_id: user.id,
                vault_id: vault.id,
                position: pos,
                char_start: 0,
                char_end: 1,
                token_count: 10,
                qdrant_point_id: Ecto.UUID.generate()
              }

        Repo.insert_all(Chunk, rows, skip_tenant_check: true)
        {user, vault, note}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(v in Engram.Vaults.Vault, where: v.id == ^vault.id),
          skip_tenant_check: true
        )

        Repo.delete!(user, skip_tenant_check: true)
        # The upsert's committed embed/link jobs would leak into later tests.
        Repo.delete_all(from(j in Oban.Job, where: j.args["user_id"] == ^user.id))
      end)
    end)

    %{note: note}
  end

  defp state(id),
    do: Maintenance.one(from(s in NoteIndexState, where: s.note_id == ^id))

  test "the pool really is the maintenance role" do
    assert %{rows: [["engram_maintenance", false, false]]} =
             Maintenance.query!(
               "SELECT current_user::text, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user"
             )
  end

  test "a chunk delete and its recount through the maintenance pool", %{note: note} do
    {:ok, _} =
      Maintenance.transaction(fn ->
        {1, _} =
          Maintenance.delete_all(
            from(c in Chunk, where: c.note_id == ^note.id and c.position == 2)
          )

        assert ChunkRows.recount!([note.id], Maintenance) == 1
      end)

    assert %{points: 2, len_rows: 2, len_sum: 20} = state(note.id)
  end

  test "the backfill fills and counts through the maintenance pool", %{note: note} do
    {1, _} = Maintenance.delete_all(from(s in NoteIndexState, where: s.note_id == ^note.id))
    assert state(note.id) == nil

    assert {:more, rows: _} = Ledger.run_pass()
    assert %{points: 3, len_rows: 3, len_sum: 30} = state(note.id)
  end
end
