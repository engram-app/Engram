defmodule Engram.NotesContentForReadTest do
  @moduledoc """
  `notes.content` is a FACADE for a CRDT-managed note: it materializes at
  checkpoint, so between a doc write and the next checkpoint the column lags the
  authority. `docs/context/worker-reads-stale-content-facade.md` records three
  read paths that took the facade and were wrong for it — append (#1159), link
  extraction, and `EmbedNote` (still open) — and #1339 added a fourth on the
  most damaging path of all: the sync change feed, where an empty facade made
  both devices materialize a 0-byte file and push the empty hash back.

  Only the BODY is resolved. `content_hash` stays the facade's — it means "hash
  of the last checkpoint", which is immutable between checkpoints and therefore
  the same on every endpoint that serves it.
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
  # A real, decryptable, valid Yjs update that changes nothing. `replay_tail/3`
  # counts a row as applied only when it DECRYPTS, and the feed now compares that
  # count against the tail size — so a junk payload would read as a partial
  # replay and degrade to the facade.
  defp noop_update do
    {:ok, %{state: state}} = Engram.Notes.CrdtBridge.merge_plaintext(nil, "")
    state
  end

  defp dek!(user) do
    {:ok, dek} = Crypto.get_dek(user)
    dek
  end

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
      Envelope.encrypt(noop_update(), dek, Crypto.aad_for_row(:notes, :crdt_state, note_id))

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

  # THE primary #1339 shape, and the one an earlier cut of this fix missed: a
  # note that has never been checkpointed has NO snapshot at all
  # (`genesis_insert_bare` writes content: "", content_hash: nil, no
  # crdt_state) and its entire body lives in the tail. Bailing on a nil
  # snapshot serves "" for exactly the notes this exists to fix.
  test "a never-checkpointed note is rebuilt from the tail alone", ctx do
    %{user: user, vault: vault} = ctx

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "genesis.md", "content" => "TAIL ONLY"})

    # Move the whole body into the tail and drop the snapshot + facade, which is
    # the state between a genesis insert and its first checkpoint.
    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, user)

    {ct, nonce} =
      Envelope.encrypt(state, dek!(user), Crypto.aad_for_row(:notes, :crdt_state, note.id))

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.insert!(%CrdtUpdateLog{
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: ct,
          update_nonce: nonce,
          inserted_at: DateTime.utc_now()
        })

        Repo.update_all(
          from(n in Note, where: n.id == ^note.id),
          set: [crdt_state_ciphertext: nil, crdt_state_nonce: nil]
        )
      end)

    :ok = blank_facade!(user, note.id)

    {:ok, %{changes: changes}} = Notes.list_changes_by_seq(user, vault, 0)
    change = Enum.find(changes, &(&1.path == "genesis.md"))

    assert change.content == "TAIL ONLY"
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

  # A checkpointed note with a NON-empty facade is served verbatim and never
  # re-read. Note what this does NOT claim: a genuinely-empty checkpointed note
  # IS re-read and rebuilt, because an empty facade is indistinguishable from
  # one a checkpoint just moved. That cost is real and bounded to empty notes.
  test "a checkpointed note with a body is served verbatim", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "f.md", "content" => "KEPT"})

    {:ok, %{changes: changes}} = Notes.list_changes_by_seq(user, vault, 0)
    change = Enum.find(changes, &(&1.path == "f.md"))

    assert change.content == "KEPT"
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

  # `replay_tail/3` logs-and-SKIPS a tail row it cannot decrypt, so a truncated
  # projection looks healthy — non-empty, so the empty-projection guard cannot
  # see it. A transient DEK fault mid-rotation would otherwise ship a body with
  # the most recent edits missing, and the client would write it to disk.
  test "a partial tail replay degrades to the facade", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "partial.md", "content" => "INTACT"})

    # One good tail row, one that will not decrypt (wrong AAD) — replay applies
    # 1 of 2, so the projection is missing ops.
    :ok = append_tail!(user, vault, note.id)

    {ct, nonce} =
      Envelope.encrypt(
        noop_update(),
        dek!(user),
        Crypto.aad_for_row(:notes, :content, note.id)
      )

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.insert!(%CrdtUpdateLog{
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: ct,
          update_nonce: nonce,
          inserted_at: DateTime.utc_now()
        })
      end)

    {:ok, %{changes: changes}} = Notes.list_changes_by_seq(user, vault, 0)
    change = Enum.find(changes, &(&1.path == "partial.md"))

    assert change.content == "INTACT"
  end

  # Resolution runs @resolve_chunk notes per transaction (the 15s Ecto default
  # would not survive a 500-row page of Yjs rebuilds). A merge bug across the
  # chunk boundary silently drops notes back to their stale facade, which is the
  # #1339 loss again — so cross a boundary and assert every note resolved.
  @tag :slow
  test "every stale note resolves across a chunk boundary", ctx do
    %{user: user, vault: vault} = ctx
    count = 55

    notes =
      for i <- 1..count do
        {:ok, note} =
          Notes.upsert_note(user, vault, %{
            "path" => "chunk/#{i}.md",
            "content" => "BODY #{i}"
          })

        :ok = blank_facade!(user, note.id)
        :ok = append_tail!(user, vault, note.id)
        {i, note}
      end

    {:ok, %{changes: changes}} = Notes.list_changes_by_seq(user, vault, 0, limit: 500)
    by_path = Map.new(changes, &{&1.path, &1})

    unresolved =
      for {i, _note} <- notes,
          Map.get(by_path, "chunk/#{i}.md").content != "BODY #{i}",
          do: i

    assert unresolved == [], "notes left on the stale facade: #{inspect(unresolved)}"
  end
end
