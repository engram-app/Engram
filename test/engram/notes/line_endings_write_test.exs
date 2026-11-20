defmodule Engram.Notes.LineEndingsWriteTest do
  # LF-only docs: a markdown write is converted to LF where it enters the doc;
  # a canvas write is stored byte-exact.
  use Engram.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Engram.MCP.Handlers
  alias Engram.Notes
  alias Engram.Notes.LineEndings
  alias Engram.Notes.NoteBody

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp write(user, vault, path, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    note
  end

  defp content(user, vault, path) do
    {:ok, note} = Notes.get_note(user, vault, path)
    {:ok, content} = Notes.authoritative_content(user, note)
    content
  end

  defp state_vector(user, note_id) do
    row =
      Engram.Repo.with_tenant!(user.id, fn ->
        NoteBody.get(note_id, [
          :id,
          :user_id,
          :vault_id,
          :dek_version,
          :crdt_state_ciphertext,
          :crdt_state_nonce
        ])
      end)

    {:ok, state} = Engram.Crypto.decrypt_crdt_state(row, user)
    {:ok, doc} = Engram.Notes.CrdtBridge.doc_from_state(state)
    Yex.encode_state_vector!(doc)
  end

  # A note written before LineEndings and never opened in a room since: a
  # raw-CRLF doc and the raw body's hash, as such rows still sit in prod.
  defp seed_legacy_crlf!(user, vault, path, crlf) do
    note = write(user, vault, path, LineEndings.to_lf(crlf))
    {:ok, %{state: state}} = Engram.Notes.CrdtBridge.merge_plaintext(nil, crlf)
    {:ok, {ct, nonce}} = Engram.Crypto.encrypt_crdt_state(state, user, note.id)
    {:ok, raw_hash} = Notes.content_hash(user, crlf)

    {:ok, _} =
      Engram.Repo.with_tenant(user.id, fn ->
        Engram.Fixtures.write_note_body!(note.id,
          crdt_state_ciphertext: ct,
          crdt_state_nonce: nonce
        )

        Engram.Repo.update_all(
          from(n in Engram.Notes.Note, where: n.id == ^note.id),
          [set: [content_hash: raw_hash]],
          skip_tenant_check: true
        )
      end)

    {note, raw_hash}
  end

  test "a markdown write with CRLF, lone CR and LF lands as LF", %{user: u, vault: v} do
    write(u, v, "Mixed.md", "---\r\ntitle: T\r\n---\r\na\r\nb\rc\n")
    assert content(u, v, "Mixed.md") == "---\ntitle: T\n---\na\nb\nc\n"
  end

  test "a canvas write keeps its bytes exactly", %{user: u, vault: v} do
    canvas = "{\r\n  \"nodes\": [],\r\n  \"edges\": []\r\n}\r"
    write(u, v, "Board.canvas", canvas)
    assert content(u, v, "Board.canvas") == canvas

    # And through a second write (the merge path, not just the insert).
    canvas2 = "{\r\n  \"nodes\": [1],\r\n  \"edges\": []\r\n}\r"
    write(u, v, "Board.canvas", canvas2)
    assert content(u, v, "Board.canvas") == canvas2
  end

  # An old plugin keeps pushing its CRLF disk bytes. Each push must converge to
  # the same LF doc: no new ops, no content change, so nothing echoes back.
  test "a repeated old-plugin CRLF write converges with no new ops", %{user: u, vault: v} do
    note = write(u, v, "Old.md", "# Old\r\n\r\nbody\r\n")
    sv = state_vector(u, note.id)
    hash = note.content_hash

    again = write(u, v, "Old.md", "# Old\r\n\r\nbody\r\n")
    assert again.content_hash == hash
    assert state_vector(u, note.id) == sv
    assert content(u, v, "Old.md") == "# Old\n\nbody\n"
  end

  # A note written before LineEndings and never opened in a room since: its doc
  # and stored hash are still raw CRLF. An identical CRLF push must stay a
  # no-op (the stored hash is the RAW body's), not rewrite it on every push.
  test "an identical push of a legacy CRLF-stored note keeps version and seq", %{
    user: u,
    vault: v
  } do
    crlf = "# Legacy\r\n\r\nbody\r\n"
    {note, raw_hash} = seed_legacy_crlf!(u, v, "Legacy.md", crlf)

    before =
      Engram.Repo.with_tenant!(u.id, fn -> Engram.Repo.get!(Engram.Notes.Note, note.id) end)

    assert before.content_hash == raw_hash

    again = write(u, v, "Legacy.md", crlf)

    after_push =
      Engram.Repo.with_tenant!(u.id, fn -> Engram.Repo.get!(Engram.Notes.Note, note.id) end)

    assert again.version == before.version
    assert after_push.version == before.version
    assert after_push.seq == before.seq
    assert after_push.content_hash == raw_hash
  end

  # Delete-wins on the raw hash: another device re-pushing the legacy CRLF note
  # it still holds, seconds after a delete, must not bring it back.
  test "a just-deleted legacy CRLF note is not resurrected by an identical push", %{
    user: u,
    vault: v
  } do
    crlf = "# Gone\r\n\r\nbody\r\n"
    seed_legacy_crlf!(u, v, "Gone.md", crlf)
    assert :ok = Notes.delete_note(u, v, "Gone.md")

    assert {:error, :recently_deleted} =
             Notes.upsert_note(u, v, %{"path" => "Gone.md", "content" => crlf}, actor: "api")
  end

  test "edit_note finds a multi-line string in a note that came in as CRLF", %{
    user: u,
    vault: v
  } do
    write(u, v, "Crlf.md", "## T\r\none\r\ntwo\r\nthree\r\n")

    assert {:ok, _, %{"replacements" => 1}} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "Crlf.md",
               "mode" => "replace_text",
               "find" => "one\ntwo",
               "replace" => "1\n2"
             })

    assert content(u, v, "Crlf.md") == "## T\n1\n2\nthree\n"
  end
end
