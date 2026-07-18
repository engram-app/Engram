defmodule Engram.Notes.GenesisCrdtNoteTest do
  use Engram.DataCase, async: false
  alias Engram.{Crypto, Notes, Vaults}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "GenesisTest"})
    %{user: user, vault: vault}
  end

  test "creates a bare empty-content row for a new id + path", %{user: user, vault: vault} do
    id = Ecto.UUID.generate()
    assert {:ok, note} = Notes.genesis_crdt_note(user, vault, id, "Notes/new.md")
    assert note.id == id
    assert note.content == ""
    # resolves by path (Phase-B path fields valid)
    assert {:ok, ^id} = fetch_id_by_path(user, vault, "Notes/new.md")
  end

  test "a malformed id is rejected, no note created", %{user: user, vault: vault} do
    assert {:error, :invalid_id} =
             Notes.genesis_crdt_note(user, vault, "not-a-uuid", "Notes/bad.md")

    assert {:error, :not_found} = Notes.get_note(user, vault, "Notes/bad.md")
  end

  test "id already live at the requested path is an idempotent no-op, content untouched", %{
    user: user,
    vault: vault
  } do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Notes/a.md", "content" => "hello"})
    assert {:ok, got} = Notes.genesis_crdt_note(user, vault, note.id, "Notes/a.md")
    assert got.id == note.id
    # content preserved
    assert got.content == "hello"
  end

  test "path owned by a live note under a different id adopts that id, content untouched", %{
    user: user,
    vault: vault
  } do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Notes/b.md", "content" => "world"})
    other = Ecto.UUID.generate()
    assert {:ok, got} = Notes.genesis_crdt_note(user, vault, other, "Notes/b.md")
    # adopted the server's id
    assert got.id == note.id
    refute Notes.note_in_vault?(user, vault.id, other)
    {:ok, still} = Notes.get_note(user, vault, "Notes/b.md")
    # untouched
    assert still.content == "world"
  end

  test "id live at a different path is an id_conflict, neither note changes", %{
    user: user,
    vault: vault
  } do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Notes/c.md", "content" => "keep"})

    assert {:error, :id_conflict, live} =
             Notes.genesis_crdt_note(user, vault, note.id, "Notes/elsewhere.md")

    assert live.id == note.id
    {:ok, still} = Notes.get_note(user, vault, "Notes/c.md")
    assert still.content == "keep"
    assert {:error, :not_found} = Notes.get_note(user, vault, "Notes/elsewhere.md")
  end

  test "same-path resurrect within the delete window is refused (delete-wins #970)", %{
    user: user,
    vault: vault
  } do
    # FIX 1 — a stale device re-creating a note at its OWN path within the
    # delete window must NOT un-delete it; the delete wins (mirrors the REST
    # upsert_pathless guard). The note stays tombstoned. A legitimate restore is
    # a rename (different path) — see the "keeps content" test below.
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "Notes/gone.md", "content" => "IMPORTANT"})

    :ok = Notes.delete_note_by_id(user, vault, note.id)
    refute Notes.note_in_vault?(user, vault.id, note.id)

    assert {:error, :recently_deleted} =
             Notes.genesis_crdt_note(user, vault, note.id, "Notes/gone.md")

    refute Notes.note_in_vault?(user, vault.id, note.id)
  end

  test "resurrecting to a different path re-paths but keeps content", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Notes/old.md", "content" => "BODY"})
    :ok = Notes.delete_note_by_id(user, vault, note.id)

    assert {:ok, back} = Notes.genesis_crdt_note(user, vault, note.id, "Notes/renamed.md")
    assert back.content == "BODY"
    {:ok, at_new} = Notes.get_note(user, vault, "Notes/renamed.md")
    assert at_new.id == note.id
  end

  test "a rename resurrect over the notes_cap still succeeds (matches REST self-recovery)", %{
    user: user,
    vault: vault
  } do
    # H1 (round-2 review, reverting round-1 FIX 4) — REST's resurrect path
    # (upsert_pathless -> move_note) has no notes_cap gate: un-deleting your OWN
    # note is self-recovery, not new creation. cap = 1: create A (fills cap),
    # delete A, create B (fills cap again), then resurrect A's id at a
    # DIFFERENT path (rename, so delete-wins doesn't trip) — this must SUCCEED
    # even though live count goes to 2 > 1.
    insert(:user_limit_override, user: user, key: "notes_cap", value: %{"v" => 1})

    {:ok, a} = Notes.upsert_note(user, vault, %{"path" => "A.md", "content" => "a"})
    :ok = Notes.delete_note_by_id(user, vault, a.id)
    {:ok, _b} = Notes.upsert_note(user, vault, %{"path" => "B.md", "content" => "b"})

    assert {:ok, note} = Notes.genesis_crdt_note(user, vault, a.id, "A-renamed.md")
    assert note.id == a.id
    assert note.content == "a"
    assert Notes.note_in_vault?(user, vault.id, a.id)
  end

  test "a rename resurrect broadcasts the new-path upsert so peers converge (FIX 7)", %{
    user: user,
    vault: vault
  } do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "Notes/from.md", "content" => "MOVE"})

    :ok = Notes.delete_note_by_id(user, vault, note.id)

    EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

    assert {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "Notes/to.md")

    # A pure announce_ready carries only the id — a rename must fan the new-path
    # upsert (note_changed) so peers see it materialize at the new path instead
    # of just the old-path delete.
    assert_receive %Phoenix.Socket.Broadcast{
      event: "note_changed",
      payload: %{"event_type" => "upsert", "path" => "Notes/to.md", "id" => id}
    }

    assert id == note.id
  end

  test "resurrect with corrupt tombstone ciphertext returns a clean error, does not raise", %{
    user: user,
    vault: vault
  } do
    # H2 — genesis_resurrect must use the non-raising decrypt so a corrupt/
    # undecryptable tombstone replies create_failed to the client instead of
    # raising out through the channel and dropping the socket.
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "Notes/corrupt.md", "content" => "SECRET"})

    :ok = Notes.delete_note_by_id(user, vault, note.id)

    raw = Engram.Fixtures.raw_note_row!(user, note.id)
    <<first, rest::binary>> = raw.content_ciphertext
    tampered_ct = <<Bitwise.bxor(first, 1), rest::binary>>

    {:ok, _} =
      Engram.Repo.with_tenant(user.id, fn ->
        raw
        |> Ecto.Changeset.change(content_ciphertext: tampered_ct)
        |> Engram.Repo.update()
      end)

    Crypto.DekCache.invalidate(user.id)

    assert {:error, _reason} =
             Notes.genesis_crdt_note(user, vault, note.id, "Notes/corrupt-renamed.md")
  end

  test "a fresh genesis announces crdt_doc_ready and does NOT deliver content", %{
    user: user,
    vault: vault
  } do
    EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")
    EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
    id = Ecto.UUID.generate()
    {:ok, _} = Notes.genesis_crdt_note(user, vault, id, "Notes/announce.md")

    # An EMPTY genesis note integrates zero Y.Doc ops, so no note_yjs_update
    # fan-out ever fires — the announce is the ONLY signal the receiver gets.
    # It must carry the path so the receiver can materialize the file live
    # (test_27) instead of discovering it ~30s later via the pull.
    assert_receive %Phoenix.Socket.Broadcast{
      event: "crdt_doc_ready",
      payload: %{"doc_id" => ^id, "path" => "Notes/announce.md"}
    }

    refute_receive %Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 200
  end

  defp fetch_id_by_path(user, vault, path) do
    case Notes.get_note(user, vault, path) do
      {:ok, n} -> {:ok, n.id}
      other -> other
    end
  end
end
