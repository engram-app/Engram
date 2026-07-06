defmodule Engram.NotesClientMintTest do
  # Phase I — contract: when a caller (plugin, SDK, e2e) supplies an `id` in
  # the upsert_note attrs, the server persists it as the row's PK. Falls back
  # to server-side mint when the supplied id is missing or malformed.
  use Engram.DataCase, async: true

  import Engram.Factory

  test "upsert_note honors client-supplied uuidv7 id" do
    user = insert(:user)
    vault = insert(:vault, user: user)
    client_minted = UUIDv7.generate()

    {:ok, note} =
      Engram.Notes.upsert_note(user, vault, %{
        "id" => client_minted,
        "path" => "/client-mint.md",
        "content" => "hello"
      })

    assert note.id == client_minted
  end

  test "upsert_note falls back to server mint on malformed client id" do
    user = insert(:user)
    vault = insert(:vault, user: user)

    {:ok, note} =
      Engram.Notes.upsert_note(user, vault, %{
        "id" => "not-a-uuid",
        "path" => "/server-mint.md",
        "content" => "hello"
      })

    assert {:ok, _} = Ecto.UUID.cast(note.id)
    refute note.id == "not-a-uuid"
  end

  test "upsert_note server-mints when no client id supplied" do
    user = insert(:user)
    vault = insert(:vault, user: user)

    {:ok, note} =
      Engram.Notes.upsert_note(user, vault, %{
        "path" => "/no-client-id.md",
        "content" => "hello"
      })

    assert is_binary(note.id)
    assert {:ok, _} = Ecto.UUID.cast(note.id)
  end

  # Phase I id-keyed rename: the plugin renames a note by keeping the same
  # note_id across a `DELETE old` + `POST new {id: same}` pair. delete_note/3
  # is a soft delete (tombstone, PK unchanged), so the re-push's client id
  # collides with the tombstone's PK. Before this fix, insert_new_note's
  # `ON CONFLICT DO NOTHING` no-op'd against the tombstone and the note never
  # materialized at the new path (see docs/context brief). upsert_note must
  # detect the id already names a row in this vault and MOVE/resurrect it
  # instead of trying to insert.
  describe "id-keyed move/resurrect" do
    test "resurrects a tombstoned id at a new path (rename)" do
      user = insert(:user)
      # Phase B reads derive a filter key from the user's DEK. Provision it
      # upfront (mirrors notes_test.exs setup) so delete_note/get_note calls
      # below don't hit a stale in-struct nil encrypted_dek.
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      vault = insert(:vault, user: user)
      id = UUIDv7.generate()

      {:ok, note} =
        Engram.Notes.upsert_note(user, vault, %{
          "id" => id,
          "path" => "A.md",
          "content" => "# Hi\nbody"
        })

      assert note.id == id

      :ok = Engram.Notes.delete_note(user, vault, "A.md")
      assert Engram.UsageMeters.notes_count(user.id) == 0

      {:ok, moved} =
        Engram.Notes.upsert_note(user, vault, %{
          "id" => id,
          "path" => "B.md",
          "content" => "# Hi\nbody"
        })

      assert moved.id == id
      assert moved.path == "B.md"
      assert moved.deleted_at == nil

      assert {:ok, _} = Engram.Notes.get_note(user, vault, "B.md")
      assert {:error, :not_found} = Engram.Notes.get_note(user, vault, "A.md")

      assert Engram.UsageMeters.notes_count(user.id) == 1
    end

    # NOTE (2026-07-06): a prior test here asserted that upserting a LIVE note's
    # id at a new path MOVES it (destroying the original at the old path). That
    # was the id-collision data-loss vector — removed. Moving a live note by id
    # is now rejected (see "rejects a live id-collision ..." below). A real
    # rename tombstones the old path first and is covered by
    # "resurrects a tombstoned id at a new path (rename)" above, which also
    # asserts the usage counter is not double-counted.

    # DATA-LOSS GUARD (prod incident 2026-07-06): on the wire, "rename A->B"
    # and "a DIFFERENT note that reuses A's note_id" are indistinguishable — a
    # single upsert to path B carrying a note_id already live at path A. The
    # old behavior MOVED + crdt-merged the live A row onto B, silently
    # destroying A and bleeding its content across notes. A live id-collision
    # must be REJECTED (conflict), never moved. Legit renames delete-first
    # (tombstone) and take the resurrect path above, so they are unaffected.
    test "rejects a live id-collision instead of collapsing two distinct notes" do
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      vault = insert(:vault, user: user)
      id = UUIDv7.generate()

      {:ok, _a} =
        Engram.Notes.upsert_note(user, vault, %{
          "id" => id,
          "path" => "A.md",
          "content" => "AAA original body"
        })

      # A different note at a different path reuses A's live note_id.
      result =
        Engram.Notes.upsert_note(user, vault, %{
          "id" => id,
          "path" => "B.md",
          "content" => "BBB different body"
        })

      # A survives intact at its original path — NOT moved, NOT merged.
      assert {:ok, a_still} = Engram.Notes.get_note(user, vault, "A.md")
      assert a_still.id == id
      assert a_still.content =~ "AAA original body"
      refute a_still.content =~ "BBB"

      # The colliding push is surfaced as a conflict, not silently applied.
      assert {:error, :version_conflict, _} = result

      # Exactly one note exists — the collision did not create/duplicate rows.
      assert Engram.UsageMeters.notes_count(user.id) == 1
    end

    test "a fresh id at a new path still inserts normally" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      id = UUIDv7.generate()

      {:ok, note} =
        Engram.Notes.upsert_note(user, vault, %{
          "id" => id,
          "path" => "C.md",
          "content" => "hello"
        })

      assert note.id == id
      assert Engram.UsageMeters.notes_count(user.id) == 1
    end
  end
end
