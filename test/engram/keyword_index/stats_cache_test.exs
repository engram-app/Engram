defmodule Engram.KeywordIndex.StatsCacheTest do
  @moduledoc """
  avgdl is cached per vault: every EmbedNote job previously ran
  `SELECT avg(token_count)` over the vault's whole chunk set, making initial
  indexing of a large vault O(N^2) in DB row visits. BM25 length-norm is a
  soft signal (the #605 re-normalize worker handles drift), so a stale value
  inside the TTL is harmless.
  """
  use Engram.DataCase, async: true

  alias Engram.KeywordIndex.Stats
  alias Engram.Notes.Chunk

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  defp insert_chunk!(user, vault, note, position, token_count) do
    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        %Chunk{}
        |> Chunk.changeset(%{
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          position: position,
          char_start: 0,
          char_end: 10,
          token_count: token_count,
          qdrant_point_id: Ecto.UUID.generate()
        })
        |> Repo.insert!()
      end)
  end

  test "second read is served from cache, not recomputed", %{user: user, vault: vault} do
    {:ok, note} =
      Engram.Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# A"})

    insert_chunk!(user, vault, note, 0, 100)
    insert_chunk!(user, vault, note, 1, 200)

    assert Stats.avgdl(vault.id) == 150.0

    # Change the underlying data; a cached read must NOT see it yet.
    insert_chunk!(user, vault, note, 2, 700)
    assert Stats.avgdl(vault.id) == 150.0
  end

  test "evict/1 forces a recompute", %{user: user, vault: vault} do
    {:ok, note} =
      Engram.Notes.upsert_note(user, vault, %{"path" => "b.md", "content" => "# B"})

    insert_chunk!(user, vault, note, 0, 100)
    assert Stats.avgdl(vault.id) == 100.0

    insert_chunk!(user, vault, note, 1, 300)
    :ok = Stats.evict(vault.id)
    assert Stats.avgdl(vault.id) == 200.0
  end

  test "empty vault default is returned and cached", %{vault: vault} do
    assert Stats.avgdl(vault.id) == 100.0
  end
end
