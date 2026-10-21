defmodule Engram.NotesWorkerFetchColumnsTest do
  # Guard: the worker note fetch does not read CRDT state.
  #
  # `fetch_note_for_worker/1,2` feeds EmbedNote, RepathNoteIndex,
  # RefreshKeywordVectors and ExtractNoteLinks' legacy (no-tenant) path.
  # None of them reads `crdt_state_*`: embedding and keywords use the decrypted
  # facade, repath uses ids and hashes, and the link worker's legacy path goes
  # through `authoritative_content/2`, which re-reads the row with its state
  # and tail. The state is about half a note's stored bytes in prod
  # (2026-10-20 audit). ExtractNoteLinks' tenant path keeps the full row
  # (`fetch_note_with_tail_for_worker/2`), since it resolves from that row.
  use Engram.DataCase, async: true

  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.QueryRecorder

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "W", Ecto.UUID.generate())

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "A.md", "content" => "hello"}, actor: "api")

    %{user: user, note: note}
  end

  defp note_selects(queries) do
    me = self()
    for %{sql: sql, pid: ^me} <- queries, sql =~ ~s(FROM "notes"), do: sql
  end

  test "the tenant fetch selects no crdt_state", %{user: u, note: note} do
    {{:ok, %Note{} = fetched}, queries} =
      QueryRecorder.record(fn -> Notes.fetch_note_for_worker(note.id, u.id) end)

    sqls = note_selects(queries)
    assert sqls != [], QueryRecorder.format(queries)
    for sql <- sqls, do: refute(sql =~ "crdt_state", sql)

    assert fetched.id == note.id
    assert fetched.content_hash == note.content_hash
    assert {:ok, %{content: "hello"}} = Engram.Crypto.maybe_decrypt_note_fields(fetched, u)
  end

  test "the legacy fetch selects no crdt_state, and authoritative_content still resolves", %{
    user: u,
    note: note
  } do
    stored = Repo.get!(Note, note.id, skip_tenant_check: true)
    assert stored.crdt_state_ciphertext, "precondition: the note has CRDT state"

    {{:ok, %Note{} = fetched}, queries} =
      QueryRecorder.record(fn -> Notes.fetch_note_for_worker(note.id) end)

    for sql <- note_selects(queries), do: refute(sql =~ "crdt_state", sql)

    {:ok, decrypted} = Engram.Crypto.maybe_decrypt_note_fields(fetched, u)
    assert {:ok, "hello"} = Notes.authoritative_content(u, decrypted)
  end

  test "a soft-deleted note still discards", %{user: u, note: note} do
    :ok =
      Notes.delete_note(
        u,
        Repo.get!(Engram.Vaults.Vault, note.vault_id, skip_tenant_check: true),
        "A.md"
      )

    assert {:discard, _} = Notes.fetch_note_for_worker(note.id, u.id)
  end
end
