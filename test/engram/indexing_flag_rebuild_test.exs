defmodule Engram.IndexingFlagRebuildTest do
  # Moved from the deleted ReindexKeyword test (#1477): re-enqueuing a rebuild
  # is a silent no-op unless the hashes AND the chunk reuse markers are cleared.
  use Engram.DataCase, async: false

  alias Engram.Indexing
  alias Engram.Notes.{Chunk, Note}
  alias Engram.Repo

  test "flag_notes_for_rebuild/2 clears embed_hash, dense_indexed_hash and chunk context_hmac" do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    note =
      insert(:note,
        user: user,
        vault: vault,
        content_hash: "same",
        embed_hash: "same",
        dense_indexed_hash: "same"
      )

    chunk =
      Repo.insert!(
        %Chunk{
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          position: 0,
          char_start: 0,
          char_end: 10,
          qdrant_point_id: Ecto.UUID.generate(),
          context_hmac: "reuse-me"
        },
        skip_tenant_check: true
      )

    assert 1 ==
             Repo.with_tenant!(user.id, fn -> Indexing.flag_notes_for_rebuild([note.id], Repo) end)

    assert is_nil(Repo.get!(Chunk, chunk.id, skip_tenant_check: true).context_hmac)

    reloaded = Repo.get!(Note, note.id, skip_tenant_check: true)
    assert is_nil(reloaded.embed_hash)
    assert is_nil(reloaded.dense_indexed_hash)
  end
end
