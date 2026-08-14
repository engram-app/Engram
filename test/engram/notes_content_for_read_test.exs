defmodule Engram.NotesContentForReadTest do
  @moduledoc """
  `notes.content` is a FACADE for a CRDT-managed note: it materializes at
  checkpoint, so between a doc write and the next checkpoint the column lags the
  authority. `docs/context/worker-reads-stale-content-facade.md` records three
  read paths that took the facade and were wrong for it — append (#1159), link
  extraction, and `EmbedNote` (still open) — and #1339 added a fourth on the
  most damaging path of all: the sync change feed, where an empty facade made
  both devices materialize a 0-byte file and push the empty hash back.

  The resolution is shared by the change feed and the manifest so the two agree
  on what `content_hash` means — the client cross-compares them.
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

  # `content_hash` deliberately stays the FACADE's, even when the body is
  # resolved. It means "hash of the last checkpoint" — immutable between
  # checkpoints, so the feed and /sync/manifest serve the same value and
  # `validateFromManifest` can use equality as a convergence fence.
  #
  # Recomputing it to match the resolved body was tried and reverted: that makes
  # it MUTABLE, so the two endpoints describe different instants of an
  # actively-edited note and every such note reads as diverged on each poll. No
  # server-side scheme fixes that — the content changes between the two calls.
  test "content_hash stays the facade's so the feed and manifest agree", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "e.md", "content" => "HASH ME"})

    {:ok, before} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    :ok = append_tail!(user, vault, note.id)

    {:ok, %{changes: changes}} = Notes.list_changes_by_seq(user, vault, 0)
    change = Enum.find(changes, &(&1.path == "e.md"))

    assert change.content_hash == before.content_hash
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

  # `.canvas` keeps its data in Y.Maps, not the markdown Y.Text, so `project_doc`
  # returns "" for it. `crdt_checkpoint.ex` refuses to materialize that over the
  # facade — the only non-Yjs copy of the board — and the read path must refuse
  # it too.
  test "a canvas note is never resolved through the markdown projection", ctx do
    %{user: user, vault: vault} = ctx

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "board.canvas", "content" => ~s({"nodes":[]})})

    :ok = append_tail!(user, vault, note.id)

    {:ok, %{changes: changes}} = Notes.list_changes_by_seq(user, vault, 0)
    change = Enum.find(changes, &(&1.path == "board.canvas"))

    assert change.content == ~s({"nodes":[]})
  end

  # `delete_note/4` only sets deleted_at; nothing prunes the tail (the FK cascade
  # is hard-delete only). Without an explicit exclusion a tombstone stays "stale"
  # forever — rebuilding a doc on every page that carries it, and shipping a
  # resurrected body on a `deleted: true` row.
  test "a tombstone is not resolved and ships no resurrected body", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "gone.md", "content" => "BODY"})

    # Blank the facade FIRST, so a rebuild would visibly resurrect "BODY" from
    # the snapshot. If the tombstone were resolved, content would come back.
    :ok = blank_facade!(user, note.id)
    :ok = append_tail!(user, vault, note.id)
    :ok = Notes.delete_note(user, vault, "gone.md")

    {:ok, %{changes: changes}} = Notes.list_changes_by_seq(user, vault, 0)
    change = Enum.find(changes, &(&1.path == "gone.md"))

    assert change.deleted
    assert change.content == "", "tombstone was resolved: #{inspect(change.content)}"
  end

  # The read-side mirror of `ensure_projection_safe/2`. Recomputing the hash
  # removes the one signal (hash/content disagreement) a client could have used
  # to distrust an empty row, so the backstop has to live here.
  test "an empty projection over a non-empty facade serves the facade", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "guard.md", "content" => "REAL"})

    # A snapshot that projects "" while the facade still holds the body: the
    # shape a genesis-empty doc takes if its ops never made it into the state.
    {:ok, %{state: empty_state}} = Engram.Notes.CrdtBridge.merge_plaintext(nil, "")
    {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state(empty_state, user, note.id)

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(
          from(n in Note, where: n.id == ^note.id),
          set: [crdt_state_ciphertext: ct, crdt_state_nonce: nonce]
        )
      end)

    :ok = append_tail!(user, vault, note.id)

    {:ok, %{changes: changes}} = Notes.list_changes_by_seq(user, vault, 0)
    change = Enum.find(changes, &(&1.path == "guard.md"))

    assert change.content == "REAL"
  end
end
