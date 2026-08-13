defmodule Engram.NotesContentForReadTest do
  @moduledoc """
  `notes.content` is a FACADE for a CRDT-managed note: it materializes at
  checkpoint, so between a doc write and the next checkpoint the column lags the
  authority. `docs/context/worker-reads-stale-content-facade.md` records three
  read paths that took the facade and were wrong for it — append (#1159), link
  extraction, and `EmbedNote` (still open) — and #1339 added a fourth on the
  most damaging path of all: the sync change feed, where an empty facade made
  both devices materialize a 0-byte file and push the empty hash back.

  `content_for_read/2` is the seam those paths should route through, so the
  choice is made once instead of re-litigated per caller.
  """
  use Engram.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Notes
  alias Engram.Notes.{CrdtUpdateLog, Note}
  alias Engram.Repo

  setup do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "ContentForRead"})
    %{user: user, vault: vault}
  end

  # Blank ONLY the facade, leaving crdt_state untouched. That is precisely the
  # state a note is in between a CRDT write and its first checkpoint — the
  # #1339 shape — and doing it directly keeps the test independent of room
  # scheduling.
  defp blank_facade!(user, note_id) do
    {:ok, dek} = Crypto.get_dek(user)
    {ct, nonce} = Envelope.encrypt("", dek, Crypto.aad_for_row(:notes, :content, note_id))

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(
          from(n in Note, where: n.id == ^note_id),
          set: [content_ciphertext: ct, content_nonce: nonce, content_hash: nil]
        )
      end)

    :ok
  end

  defp reload!(user, note_id) do
    {:ok, note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note_id) end)
    {:ok, decrypted} = Crypto.maybe_decrypt_note_fields(note, user)
    decrypted
  end

  describe "content_for_read/2 (the per-note seam)" do
    test "resolves the authority when the note has uncheckpointed ops", ctx do
      %{user: user, vault: vault} = ctx
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "s1.md", "content" => "REAL BODY"})
      :ok = blank_facade!(user, note.id)
      :ok = append_tail!(user, vault, note.id)

      assert {:ok, "REAL BODY"} = Notes.content_for_read(user, reload!(user, note.id))
    end

    test "serves the facade verbatim when the tail is empty", ctx do
      %{user: user, vault: vault} = ctx
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "s2.md", "content" => "BODY"})

      # Facade and doc deliberately disagree, with no tail. A checkpointed note
      # must be served as-is — rebuilding here is what makes the correct call
      # too expensive to be anyone's default.
      {:ok, dek} = Crypto.get_dek(user)
      {ct, n} = Envelope.encrypt("FACADE", dek, Crypto.aad_for_row(:notes, :content, note.id))

      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          Repo.update_all(
            from(x in Note, where: x.id == ^note.id),
            set: [content_ciphertext: ct, content_nonce: n]
          )
        end)

      assert {:ok, "FACADE"} = Notes.content_for_read(user, reload!(user, note.id))
    end

    test "a genuinely empty checkpointed note stays on the fast path", ctx do
      %{user: user, vault: vault} = ctx
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "s3.md", "content" => ""})

      assert {:ok, ""} = Notes.content_for_read(user, reload!(user, note.id))
    end
  end

  # Appends a tail row so the note reads as "has uncheckpointed ops" without
  # standing up a real room. The tail IS the staleness marker: content
  # materializes at checkpoint and `prune_tail/2` clears the tail in the same
  # breath, so tail-present means the facade lags.
  defp append_tail!(user, vault, note_id) do
    {:ok, dek} = Crypto.get_dek(user)

    {ct, nonce} =
      Envelope.encrypt(<<0>>, dek, Crypto.aad_for_row(:crdt_update_log, :update, note_id))

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.insert!(%CrdtUpdateLog{
          note_id: note_id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: ct,
          update_nonce: nonce,
          inserted_at: DateTime.utc_now()
        })
      end)

    :ok
  end

  # The regression this seam exists for. The catch-up feed is what the plugin's
  # applyChange reads, and serving "" for a note whose doc holds a body is what
  # made both devices create a 0-byte file and push back the hash of "".
  test "the seq change feed serves the doc body, not an empty facade", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "d.md", "content" => "FEED BODY"})
    :ok = blank_facade!(user, note.id)
    :ok = append_tail!(user, vault, note.id)

    {:ok, %{changes: changes}} = Notes.list_changes_by_seq(user, vault, 0)
    change = Enum.find(changes, &(&1.path == "d.md"))

    assert change.content == "FEED BODY"
  end

  # The hash is the IDENTITY of the content as far as the plugin is concerned:
  # it stamps `serverHash` from it, then skips any later row whose hash matches.
  # Shipping a resolved body under the facade's stale hash would record
  # `serverHash = hmac("")` for a file holding a body, after which a genuine
  # emptying of that note arrives as ""/hmac("") and is skipped forever.
  test "content_hash is recomputed to match the body actually served", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "e.md", "content" => "HASH ME"})
    :ok = blank_facade!(user, note.id)
    :ok = append_tail!(user, vault, note.id)

    {:ok, %{changes: changes}} = Notes.list_changes_by_seq(user, vault, 0)
    change = Enum.find(changes, &(&1.path == "e.md"))
    {:ok, key} = Crypto.dek_content_hash_key(user)

    assert change.content == "HASH ME"
    assert change.content_hash == Crypto.hmac_content_hash(key, "HASH ME")
  end

  # A checkpointed note has no tail, so it must NOT pay a Yjs rebuild. This is
  # the guard on the cost claim: genuinely-empty notes are common in a real
  # vault, and an "is the facade empty" predicate would drag every one of them
  # onto the slow path on every page.
  test "a checkpointed note serves the facade verbatim, tail-free", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "f.md", "content" => ""})

    {:ok, %{changes: changes}} = Notes.list_changes_by_seq(user, vault, 0)
    change = Enum.find(changes, &(&1.path == "f.md"))

    assert change.content == ""
    refute is_nil(change.content_hash)
  end

  # `fields: :meta` promises `content: nil` and its projection does not even
  # select crdt_state, so it must never resolve the authority.
  test "fields: :meta carries no content and resolves nothing", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "g.md", "content" => "BODY"})
    :ok = blank_facade!(user, note.id)
    :ok = append_tail!(user, vault, note.id)

    {:ok, %{changes: changes}} = Notes.list_changes_by_seq(user, vault, 0, fields: :meta)
    change = Enum.find(changes, &(&1.path == "g.md"))

    assert change.content == nil
  end

  # An undecodable crdt_state must NOT fail the page. The feed is keyset-ordered
  # by seq, so a deterministic failure on one note would wedge the whole vault's
  # catch-up permanently and crash crdt_catchup_since into a rejoin loop. The
  # facade is the last good checkpoint — stale, but real.
  test "an unreadable CRDT snapshot degrades to the facade instead of failing the page", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "h.md", "content" => "LAST GOOD"})
    :ok = append_tail!(user, vault, note.id)

    # Corrupt the snapshot only: AES-GCM auth fails, the row's other columns
    # still decrypt fine.
    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    ct = raw.crdt_state_ciphertext
    last = byte_size(ct) - 1
    <<head::binary-size(last), b>> = ct

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(
          from(n in Note, where: n.id == ^note.id),
          set: [crdt_state_ciphertext: <<head::binary, Bitwise.bxor(b, 0xFF)>>]
        )
      end)

    {:ok, %{changes: changes}} = Notes.list_changes_by_seq(user, vault, 0)
    change = Enum.find(changes, &(&1.path == "h.md"))

    assert change.content == "LAST GOOD"
  end
end
