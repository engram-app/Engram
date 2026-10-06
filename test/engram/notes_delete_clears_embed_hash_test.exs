defmodule Engram.NotesDeleteClearsEmbedHashTest do
  @moduledoc """
  #1610: a soft-deleted note keeps `embed_hash`, `DeleteNoteIndex` drops its
  points, and on resurrection `embed_hash == content_hash` so
  `ReconcileEmbeddings` skips it forever. Every live -> deleted transition must
  null `embed_hash` so a resurrected note is picked up for re-embedding.
  """
  use Engram.DataCase, async: true

  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Repo

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp embedded_note(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "# body"}, actor: "api")

    from(n in Note, where: n.id == ^note.id)
    |> Repo.update_all([set: [embed_hash: "stamped", dense_indexed_hash: "stamped"]],
      skip_tenant_check: true
    )

    note
  end

  # Both columns, as a pair: `Indexing.flag_notes_for_rebuild/2` documents
  # that clearing only one of them is a silent no-op.
  defp embed_hash(note) do
    Repo.one(
      from(n in Note,
        where: n.id == ^note.id,
        select: {n.embed_hash, n.dense_indexed_hash}
      ),
      skip_tenant_check: true
    )
  end

  test "delete_note nulls both index hashes", %{user: user, vault: vault} do
    note = embedded_note(user, vault, "A.md")
    :ok = Notes.delete_note(user, vault, "A.md")
    assert embed_hash(note) == {nil, nil}
  end

  test "batch_delete_notes nulls both index hashes", %{user: user, vault: vault} do
    note = embedded_note(user, vault, "B.md")
    {:ok, _} = Notes.batch_delete_notes(user, vault, [note.id])
    assert embed_hash(note) == {nil, nil}
  end

  test "delete_folder nulls both index hashes", %{user: user, vault: vault} do
    note = embedded_note(user, vault, "Dir/C.md")
    {:ok, _} = Notes.delete_folder(user, vault, "Dir")
    assert embed_hash(note) == {nil, nil}
  end
end
