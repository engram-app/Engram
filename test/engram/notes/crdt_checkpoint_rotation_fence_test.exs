defmodule Engram.Notes.CrdtCheckpointRotationFenceTest do
  @moduledoc """
  A checkpoint must not write a snapshot the current DEK generation cannot read
  back (#1341).

  `Crypto.encrypt_crdt_state/3` uses the user's CURRENT DEK. `UserDekRotation`
  rewraps every row and then flips that DEK. A checkpoint landing inside the
  rotation window therefore writes an OLD-DEK snapshot over a row the sweep has
  already rewrapped — and `CrdtPersistence.bind/3` is fail-loud on an unreadable
  snapshot, so that note can never be opened or synced again from any device.

  `RotationGate` in `checkpoint/5` covers all four legs (room unbind, debounce
  timer, channel, `CheckpointNote`). The unbind leg is the one that matters:
  `rotate_user/1` calls `SessionInvalidator.disconnect_user/1` at the TOP of the
  rotation, which is precisely what makes rooms terminate and checkpoint.
  The gate is a check-then-act: a lock acquired between the user read and the
  row write still slips through. That residual window is narrow and is tracked
  on the issue — closing it needs the sweep to drain rooms and WAIT, not another
  guard here.

  Skipping rather than failing is what makes this safe: nothing is pruned, so
  every edit stays in the tail-WAL and replays on the next bind.
  """
  use Engram.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Crypto.DekCache
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, CrdtUpdateLog, Note}
  alias Engram.Repo

  setup do
    DekCache.invalidate_all()
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "RotationFence"})
    %{user: user, vault: vault}
  end

  test "a checkpoint is skipped while a DEK rotation holds the lock", ctx do
    %{user: user, vault: vault} = ctx

    {:ok, note} =
      Engram.Notes.upsert_note(user, vault, %{"path" => "fence/a.md", "content" => "body"})

    before = reload(user, note.id)

    # Exactly what RotationLock.acquire/1 writes. Every leg of the checkpoint
    # resolves the user itself, so setting the column is enough to simulate the
    # window without running a real rotation.
    lock!(user.id)

    doc = doc_with("body and more")
    assert :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    after_run = reload(user, note.id)

    assert after_run.crdt_state_ciphertext == before.crdt_state_ciphertext,
           """
           the checkpoint wrote a snapshot with the pre-rotation DEK while the
           rotation lock was held. The sweep rewraps every row and then flips the
           DEK, so this row is now unreadable and bind/3 will raise on it.
           """

    # And nothing was materialized either — content must be untouched.
    assert after_run.content_hash == before.content_hash
    assert after_run.version == before.version
  end

  test "a checkpoint on an unlocked user still writes", ctx do
    %{user: user, vault: vault} = ctx

    {:ok, note} =
      Engram.Notes.upsert_note(user, vault, %{"path" => "fence/d.md", "content" => "body"})

    before = reload(user, note.id)

    doc = doc_with("body and more")
    assert :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    after_run = reload(user, note.id)

    # The guard must not be so broad it stops the normal path — otherwise the
    # test above would pass with checkpointing entirely broken.
    refute after_run.crdt_state_ciphertext == before.crdt_state_ciphertext

    # The checkpoint UNIONS the stored state with the live doc rather than
    # replacing it (identity-as-CRDT), so assert the new text landed, not that
    # it is the whole body.
    {:ok, fresh} = Crypto.maybe_decrypt_note_fields(after_run, user)
    assert fresh.content =~ "and more"
  end

  test "the detached rebuild refuses an UNREADABLE snapshot instead of rebuilding from the tail",
       ctx do
    %{user: user, vault: vault} = ctx

    {:ok, note} =
      Engram.Notes.upsert_note(user, vault, %{
        "path" => "fence/e.md",
        "content" => "THE WHOLE BODY"
      })

    # A delta sitting ON TOP of the snapshot — the shape a live edit leaves.
    seed_tail!(user, vault, note.id, "fragment")

    # Now corrupt the snapshot. This is what a half-finished rotation leaves
    # behind: the tail is readable, the snapshot is not.
    Repo.update_all(
      from(n in Note, where: n.id == ^note.id),
      [
        set: [
          crdt_state_ciphertext: :crypto.strong_rand_bytes(64),
          crdt_state_nonce: :crypto.strong_rand_bytes(12)
        ]
      ],
      skip_tenant_check: true
    )

    before = reload(user, note.id)

    # rebuild_detached must NOT treat "will not decrypt" as "absent". Replaying
    # the tail onto an empty doc yields a base-less fragment, and checkpointing
    # that materializes the fragment over the body AND prunes the tail that
    # proved it wrong. bind/3 raises on this signal for exactly this reason.
    assert :skip =
             Engram.Workers.CheckpointNote.rebuild_detached(user.id, vault.id, note.id),
           """
           the detached rebuild accepted an unreadable snapshot and fell back to
           the tail alone. finalize/1 would then write a base-less fragment over
           notes.content and prune the tail.
           """

    after_run = reload(user, note.id)
    assert after_run.content_ciphertext == before.content_ciphertext

    {:ok, remaining} =
      Repo.with_tenant(user.id, fn ->
        Repo.aggregate(from(l in CrdtUpdateLog, where: l.note_id == ^note.id), :count)
      end)

    assert remaining == 1, "the tail must survive: it is the only copy of that edit"
  end

  defp seed_tail!(user, vault, note_id, text) do
    {:ok, doc} = CrdtBridge.doc_from_state(nil)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), text)
    {:ok, update} = Yex.encode_state_as_update(doc)
    {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state(update, user, note_id)

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        %CrdtUpdateLog{}
        |> CrdtUpdateLog.changeset(%{
          note_id: note_id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: ct,
          update_nonce: nonce
        })
        |> Repo.insert!()
      end)

    :ok
  end

  defp lock!(user_id) do
    Repo.update_all(
      from(u in User, where: u.id == ^user_id),
      [set: [dek_rotation_locked_at: DateTime.utc_now()]],
      skip_tenant_check: true
    )
  end

  defp reload(user, note_id) do
    {:ok, note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note_id) end)
    note
  end

  defp doc_with(text) do
    {:ok, doc} = CrdtBridge.doc_from_state(nil)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), text)
    doc
  end
end
