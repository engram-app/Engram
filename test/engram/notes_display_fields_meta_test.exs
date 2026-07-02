defmodule Engram.NotesDisplayFieldsMetaTest do
  @moduledoc """
  `display_fields_by_qdrant_points/2` only needs path + tags, so it must not
  load or decrypt note CONTENT (up to candidate-pool notes per `/api/search`
  request — the content decrypt was the dominant cost of every search).

  Proof: a row whose content ciphertext is corrupted must still rehydrate —
  the old full-struct path decrypts content, fails, and silently drops the
  point from the result map.
  """
  use Engram.DataCase, async: true

  alias Engram.Notes
  alias Engram.Notes.Chunk

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  test "rehydrates path/tags without touching content ciphertext", %{
    user: user,
    vault: vault
  } do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{
        "path" => "Health/iron.md",
        "content" => "---\ntags: [labs]\n---\n# Iron\n\nFerritin levels.",
        "mtime" => 1_000.0
      })

    point_id = Ecto.UUID.generate()

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        %Chunk{}
        |> Chunk.changeset(%{
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          position: 0,
          char_start: 0,
          char_end: 10,
          qdrant_point_id: point_id
        })
        |> Repo.insert!()
      end)

    # Corrupt the content ciphertext at rest. Any code path that decrypts
    # content now fails; the meta projection never reads the column.
    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        from(n in Notes.Note, where: n.id == ^note.id)
        |> Repo.update_all(set: [content_ciphertext: <<0, 1, 2, 3>>])
      end)

    result = Notes.display_fields_by_qdrant_points(user, [point_id])

    assert %{source_path: "Health/iron.md", tags: ["labs"]} = result[point_id]
  end
end
