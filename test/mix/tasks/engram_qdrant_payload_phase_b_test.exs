defmodule Mix.Tasks.Engram.QdrantPayloadPhaseBTest do
  @moduledoc """
  Phase B.2.5 — mix task that enqueues `Engram.Workers.QdrantPayloadPhaseB`
  jobs from the chunks table. Skips (user, vault) pairs with no chunks
  (nothing to PATCH in Qdrant).
  """

  use Engram.DataCase, async: false

  alias Engram.Notes.Chunk
  alias Engram.Repo
  alias Mix.Tasks.Engram.QdrantPayloadPhaseB

  describe "gather_pairs/0" do
    test "returns {user_id, vault_id} pairs that have chunks, excluding chunkless vaults" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      chunkless_vault = insert(:vault, user: user)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(
        Chunk,
        [
          %{
            note_id: insert_note_for(user, vault).id,
            user_id: user.id,
            vault_id: vault.id,
            position: 0,
            heading_path: "h",
            char_start: 0,
            char_end: 1,
            qdrant_point_id: Ecto.UUID.generate(),
            created_at: now
          }
        ],
        skip_tenant_check: true
      )

      pairs = QdrantPayloadPhaseB.gather_pairs()

      assert {user.id, vault.id} in pairs
      refute {user.id, chunkless_vault.id} in pairs
    end

    test "deduplicates pairs across many chunks of the same (user, vault)" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      note = insert_note_for(user, vault)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(
        Chunk,
        for i <- 0..4 do
          %{
            note_id: note.id,
            user_id: user.id,
            vault_id: vault.id,
            position: i,
            heading_path: "h",
            char_start: i * 10,
            char_end: i * 10 + 5,
            qdrant_point_id: Ecto.UUID.generate(),
            created_at: now
          }
        end,
        skip_tenant_check: true
      )

      pairs = QdrantPayloadPhaseB.gather_pairs()

      assert Enum.count(pairs, fn p -> p == {user.id, vault.id} end) == 1
    end

    test "excludes (user, vault) pairs that have zero chunks" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      _note_without_chunks = insert_note_for(user, vault)

      pairs = QdrantPayloadPhaseB.gather_pairs()

      refute {user.id, vault.id} in pairs
    end

    test "returns empty list when no chunks exist anywhere" do
      assert QdrantPayloadPhaseB.gather_pairs() == []
    end
  end

  defp insert_note_for(user, vault) do
    {:ok, note} =
      Repo.with_tenant(user.id, fn ->
        Engram.Notes.Note.changeset(%Engram.Notes.Note{}, %{
          path: "fixtures/n-#{System.unique_integer([:positive])}.md",
          folder: "fixtures",
          content: "x",
          tags: [],
          user_id: user.id,
          vault_id: vault.id
        })
        |> Repo.insert!()
      end)

    note
  end
end
