defmodule Engram.Notes.ChunkTest do
  use Engram.DataCase, async: true

  alias Engram.Notes.Chunk

  test "changeset accepts token_count" do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)

    cs =
      Chunk.changeset(%Chunk{}, %{
        position: 0,
        char_start: 0,
        char_end: 10,
        token_count: 7,
        qdrant_point_id: Ecto.UUID.generate(),
        note_id: note.id,
        user_id: user.id,
        vault_id: vault.id
      })

    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :token_count) == 7
  end
end
