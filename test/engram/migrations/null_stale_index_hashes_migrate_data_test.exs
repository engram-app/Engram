defmodule Engram.Repo.Migrations.NullStaleIndexHashesMigrateDataTest do
  # async: false: the migration takes ACCESS EXCLUSIVE locks on notes/chunks.
  use Engram.DataCase, async: false

  alias Engram.Notes.{Chunk, Note}
  alias Engram.Repo

  Code.require_file(
    "priv/repo/migrations/20261004120000_null_stale_index_hashes_migrate_data.exs"
  )

  alias Engram.Repo.Migrations.NullStaleIndexHashesMigrateData, as: Migration

  setup do
    user = insert(:user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp stamped(user, vault, attrs) do
    insert(
      :note,
      Keyword.merge(
        [user: user, vault: vault, embed_hash: "h", dense_indexed_hash: "h", content_hash: "h"],
        attrs
      )
    )
  end

  defp with_chunk(note) do
    Repo.insert!(
      %Chunk{
        note_id: note.id,
        user_id: note.user_id,
        vault_id: note.vault_id,
        position: 0,
        char_start: 0,
        char_end: 1,
        qdrant_point_id: Ecto.UUID.generate()
      },
      skip_tenant_check: true
    )

    note
  end

  defp hashes(note) do
    Repo.one(
      from(n in Note, where: n.id == ^note.id, select: {n.embed_hash, n.dense_indexed_hash}),
      skip_tenant_check: true
    )
  end

  defp migrate, do: Enum.each(Migration.statements(), &Repo.query!/1)

  test "clears tombstones and chunkless live notes, keeps indexed ones", %{
    user: user,
    vault: vault
  } do
    tombstone = stamped(user, vault, deleted_at: DateTime.utc_now())
    resurrected = stamped(user, vault, [])
    indexed = user |> stamped(vault, []) |> with_chunk()

    migrate()

    assert hashes(tombstone) == {nil, nil}
    assert hashes(resurrected) == {nil, nil}
    assert hashes(indexed) == {"h", "h"}
  end

  test "refuses when chunks read empty but live notes are stamped", %{user: user, vault: vault} do
    # No chunk rows anywhere is what an RLS-filtered read looks like.
    stamped(user, vault, [])

    assert_raise Postgrex.Error, ~r/refusing a corpus-wide re-embed/, fn -> migrate() end
  end
end
