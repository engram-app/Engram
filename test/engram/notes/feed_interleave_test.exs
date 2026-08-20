defmodule Engram.Notes.FeedInterleaveTest do
  @moduledoc """
  The sibling of `checkpoint_interleave_test.exs`, for the READ side (#1339).

  The change feed resolves the CRDT authority for notes whose facade lags. That
  resolution reads a snapshot and replays a tail, and `checkpoint_write` folds
  the tail INTO a new snapshot and prunes it in one transaction. So the read has
  a window: if it takes its snapshot from the page SELECT and its tail from a
  later statement, a checkpoint committing in between leaves it rebuilding from
  a PRE-checkpoint snapshot against an already-pruned tail.

  For a never-checkpointed note — whose entire body lives in the tail — that
  projects "". The client writes a 0-byte file and pushes back the hash of "",
  which is #1339 itself, through a narrower window.

  The fix is that the resolution re-reads the row inside the same transaction as
  the tail. Proving it needs real connections and a park point, for the reason
  `Engram.CheckpointInterleave` documents at length: the sandbox is one
  connection in one never-committed transaction, so nothing can commit into the
  gap and a sandboxed version of this test proves nothing at all.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Engram.Factory

  alias Engram.CheckpointInterleave
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Notes
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, CrdtUpdateLog, Note}
  alias Engram.Repo

  setup do
    CheckpointInterleave.checkout_real!()

    email = "feed-interleave-#{System.unique_integer([:positive])}-#{System.os_time()}@test.com"

    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user = insert(:user, id: user_id, email: email)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "FeedInterleave", Ecto.UUID.generate())

    %{user: user, vault: vault}
  end

  test "a checkpoint committing mid-page does not make the feed serve an empty body", ctx do
    %{user: user, vault: vault} = ctx

    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "feed.md", "content" => "TAIL BODY"})

    # Put the note in the never-checkpointed shape: the whole body in the tail,
    # no snapshot, blank facade. That is what a CRDT-genesis note looks like
    # before its first checkpoint, and it is the shape whose resolution depends
    # entirely on the tail still being there.
    raw = Repo.one!(from(n in Note, where: n.id == ^note.id), skip_tenant_check: true)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, user)
    {:ok, dek} = Crypto.get_dek(user)

    {upd_ct, upd_nonce} =
      Envelope.encrypt(state, dek, Crypto.aad_for_row(:notes, :crdt_state, note.id))

    {blank_ct, blank_nonce} =
      Envelope.encrypt("", dek, Crypto.aad_for_row(:notes, :content, note.id))

    Repo.insert!(
      %CrdtUpdateLog{
        note_id: note.id,
        user_id: user.id,
        vault_id: vault.id,
        update_ciphertext: upd_ct,
        update_nonce: upd_nonce,
        inserted_at: DateTime.utc_now()
      },
      skip_tenant_check: true
    )

    Repo.update_all(
      from(n in Note, where: n.id == ^note.id),
      [
        set: [
          crdt_state_ciphertext: nil,
          crdt_state_nonce: nil,
          content_ciphertext: blank_ct,
          content_nonce: blank_nonce,
          # nil, matching `genesis_insert_bare`. Leaving the old hash in place
          # would make the checkpoint see prev == content_hash and take the
          # COMPACTION branch, which never touches notes.content — so the test
          # would be asserting against a state production never reaches.
          content_hash: nil
        ]
      ],
      skip_tenant_check: true
    )

    on_exit(CheckpointInterleave.arm(:feed_after_page_read))

    reader =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()
        Notes.list_changes_by_seq(user, vault, 0)
      end)

    parked = CheckpointInterleave.await_parked(:feed_after_page_read, reader.pid)

    # The checkpoint commits while the feed holds its page. It folds the tail
    # into a fresh snapshot, materializes the body back into notes.content, and
    # PRUNES the tail — so a resolution still trusting the page's captured row
    # would find a nil snapshot and nothing to replay.
    checkpointer =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()
        {:ok, live} = CrdtBridge.doc_from_state(state)
        CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, live)
      end)

    assert :ok = Task.await(checkpointer, 15_000)

    CheckpointInterleave.release(:feed_after_page_read, parked)

    assert {:ok, %{changes: changes}} = Task.await(reader, 15_000)
    change = Enum.find(changes, &(&1.path == "feed.md"))

    assert change.content == "TAIL BODY",
           """
           the feed served #{inspect(change.content)} for a note that holds
           "TAIL BODY". A checkpoint committed between the page SELECT and the
           resolution, folding the tail into a new snapshot and pruning it — so
           a resolution reading the snapshot from the page and the tail from a
           later statement finds neither. The client writes that to disk as a
           0-byte file and pushes the empty hash back: #1339.
           """
  end
end
