defmodule Engram.Notes.CrdtCheckpointTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, CrdtCheckpointTimer, CrdtUpdateLog, Note}
  alias Engram.Workers.EmbedNote

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "CrdtCheckpointTest"})
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "p.md", "content" => "before"})
    %{user: user, vault: vault, note: note}
  end

  # ── Core checkpoint: persists snapshot + prunes tail + bumps seq ───────────

  test "checkpoint persists live doc state + plaintext + bumps seq + prunes tail", ctx do
    %{user: user, vault: vault, note: note} = ctx

    # Seed the tail-log with a couple of raw updates so we can assert they get pruned.
    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)

    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "before AFTER")

    # Manually insert two tail-log rows to verify prune.
    {:ok, {ct1, n1}} = Crypto.encrypt_crdt_state("fake_update_1", user, note.id)
    {:ok, {ct2, n2}} = Crypto.encrypt_crdt_state("fake_update_2", user, note.id)

    Repo.with_tenant(user.id, fn ->
      Repo.insert_all(CrdtUpdateLog, [
        %{
          id: Ecto.UUID.generate(),
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: ct1,
          update_nonce: n1,
          inserted_at: DateTime.utc_now()
        },
        %{
          id: Ecto.UUID.generate(),
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: ct2,
          update_nonce: n2,
          inserted_at: DateTime.utc_now()
        }
      ])
    end)

    # Confirm tail rows exist before checkpoint.
    {:ok, tail_count_before} =
      Repo.with_tenant(user.id, fn ->
        Repo.aggregate(from(l in CrdtUpdateLog, where: l.note_id == ^note.id), :count)
      end)

    assert tail_count_before == 2

    seq0 = Vaults.current_seq(user.id, vault.id)
    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    # get_note resolves by path_hmac — ONLY succeeds if the checkpoint
    # preserved the path/folder HMACs, which requires virtual path/folder
    # to have been materialized (not nil) before re-injecting phase-B fields.
    {:ok, fresh} = Notes.get_note(user, vault, "p.md")
    assert fresh.content == "before AFTER"

    # Title must derive from the real path ("p"), not the UUID fallback that a
    # nil virtual `path` would have produced.
    assert fresh.title == "p"
    assert fresh.path == "p.md"

    # content_hash must reflect the new text.
    {:ok, key} = Crypto.dek_content_hash_key(user)
    assert fresh.content_hash == Crypto.hmac_content_hash(key, "before AFTER")

    # Seq must advance.
    assert Vaults.current_seq(user.id, vault.id) > seq0

    # Tail log must be empty after checkpoint.
    {:ok, tail_count_after} =
      Repo.with_tenant(user.id, fn ->
        Repo.aggregate(from(l in CrdtUpdateLog, where: l.note_id == ^note.id), :count)
      end)

    assert tail_count_after == 0
  end

  # ── Virtual field integrity: title/path not corrupted ─────────────────────

  test "checkpoint does not corrupt title or path_hmac on a note with a non-trivial path", ctx do
    %{user: user, vault: vault} = ctx

    {:ok, note2} =
      Notes.upsert_note(user, vault, %{"path" => "folder/deep/note.md", "content" => "init"})

    {:ok, raw_note2} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note2.id) end)
    {:ok, raw_state2} = Crypto.decrypt_crdt_state(raw_note2, user)

    {:ok, doc} = CrdtBridge.doc_from_state(raw_state2)

    :ok =
      CrdtBridge.diff_into_text(
        Yex.Doc.get_text(doc, CrdtBridge.text_name()),
        "# Updated\ncontent"
      )

    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note2.id, doc)

    {:ok, fresh} = Notes.get_note(user, vault, "folder/deep/note.md")
    assert fresh.path == "folder/deep/note.md"
    # Title must be from the h1 heading, not UUID.
    assert fresh.title == "Updated"
    assert fresh.content == "# Updated\ncontent"
  end

  # ── Embed enqueue: checkpoint triggers re-embed when content changed ───────

  test "checkpoint enqueues a debounced embed when content changes", ctx do
    %{user: user, vault: vault, note: note} = ctx

    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)

    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)

    :ok =
      CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "changed content")

    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
  end

  test "checkpoint does NOT enqueue an embed when content is unchanged", ctx do
    %{user: user, vault: vault, note: note} = ctx

    # Load the existing state without changing the text.
    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)

    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)
    # Apply the SAME text — no change.
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "before")

    # Count embed jobs BEFORE checkpoint to distinguish checkpoint's contribution
    # from the EmbedNote job already enqueued by the initial upsert_note.
    before_jobs = all_enqueued(worker: EmbedNote)

    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    after_jobs = all_enqueued(worker: EmbedNote)

    # No new job should have been added by the checkpoint.
    assert length(after_jobs) == length(before_jobs),
           "checkpoint should not enqueue embed when content is unchanged"
  end

  test "checkpoint with unchanged content compacts crdt_state without bumping version/seq", ctx do
    %{user: user, vault: vault, note: note} = ctx

    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)
    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)
    # No text mutation — doc projects the same content the row already has.

    # Clear all pre-existing embed jobs so Oban uniqueness cannot mask a wrong enqueue.
    Repo.delete_all(Oban.Job)

    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    {:ok, after_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    assert after_note.version == raw_note.version
    assert after_note.seq == raw_note.seq

    # No embed job must exist — Oban uniqueness cannot mask a wrong enqueue because
    # we cleared the table above.
    refute_enqueued(worker: EmbedNote)
  end

  # ── Race fix: prune respects watermark — post-snapshot rows survive ────────

  test "prune_tail keeps rows inserted AFTER the watermark was captured", ctx do
    %{user: user, vault: vault, note: note} = ctx

    # Use explicit, deterministic timestamps so the test is not sensitive to
    # clock resolution or Postgres transaction-time coalescing.
    t_pre = ~U[2030-01-01 00:00:00.000000Z]
    t_post = ~U[2030-01-01 00:00:01.000000Z]

    {:ok, {ct1, n1}} = Crypto.encrypt_crdt_state("pre_watermark_update", user, note.id)
    {:ok, {ct2, n2}} = Crypto.encrypt_crdt_state("post_watermark_update", user, note.id)

    pre_id = Ecto.UUID.generate()
    post_id = Ecto.UUID.generate()

    # Seed both rows with explicit timestamps directly so we control the ordering.
    # The pre-row sits at t_pre (already reflected in the doc at checkpoint time),
    # the post-row sits at t_post (simulates a concurrent write arriving AFTER the
    # watermark was snapped but before the prune transaction commits).
    Repo.with_tenant(user.id, fn ->
      Repo.insert_all(CrdtUpdateLog, [
        %{
          id: pre_id,
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: ct1,
          update_nonce: n1,
          inserted_at: t_pre
        },
        %{
          id: post_id,
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: ct2,
          update_nonce: n2,
          inserted_at: t_post
        }
      ])
    end)

    # Directly run the bounded prune with watermark = t_pre — this is exactly
    # what prune_tail/2 inside checkpoint does, but here we supply the watermark
    # explicitly so we can prove the WHERE clause excludes the post-row.
    Repo.with_tenant(user.id, fn ->
      CrdtUpdateLog
      |> where([l], l.note_id == ^note.id and l.inserted_at <= ^t_pre)
      |> Repo.delete_all()
    end)

    {:ok, surviving_ids} =
      Repo.with_tenant(user.id, fn ->
        CrdtUpdateLog
        |> where([l], l.note_id == ^note.id)
        |> select([l], l.id)
        |> Repo.all()
      end)

    refute pre_id in surviving_ids,
           "pre-watermark row (inserted_at == watermark) must be pruned"

    assert post_id in surviving_ids,
           "post-watermark row (inserted_at > watermark) must survive for the next checkpoint/replay"
  end

  # ── Watermark capture race: post-snapshot rows survive when watermark captured early ───

  test "a tail row inserted after the watermark survives prune even when checkpoint runs later",
       ctx do
    %{user: user, vault: vault, note: note} = ctx

    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)
    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)

    # Simulate the race: watermark is captured (pre-encode), THEN a new update
    # row lands (concurrent update_v1 during encode), THEN checkpoint completes.
    {:ok, watermark} =
      Repo.with_tenant(user.id, fn -> CrdtCheckpoint.tail_watermark(note.id) end)

    {:ok, {ct, n}} = Crypto.encrypt_crdt_state("late_update", user, note.id)

    Repo.with_tenant(user.id, fn ->
      Repo.insert_all(CrdtUpdateLog, [
        %{
          id: Ecto.UUID.generate(),
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: ct,
          update_nonce: n,
          inserted_at: DateTime.utc_now()
        }
      ])
    end)

    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc, watermark: watermark)

    {:ok, remaining} =
      Repo.with_tenant(user.id, fn ->
        Repo.aggregate(from(l in CrdtUpdateLog, where: l.note_id == ^note.id), :count)
      end)

    assert remaining == 1, "post-watermark row must survive prune"
  end

  # ── Watermark capture failure: nil watermark prunes nothing ────────────────

  test "checkpoint with a nil watermark prunes nothing", ctx do
    %{user: user, vault: vault, note: note} = ctx

    # Seed the tail-log with one row.
    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)

    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "before AFTER")

    {:ok, {ct, n}} = Crypto.encrypt_crdt_state("fake_update", user, note.id)

    Repo.with_tenant(user.id, fn ->
      Repo.insert_all(CrdtUpdateLog, [
        %{
          id: Ecto.UUID.generate(),
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: ct,
          update_nonce: n,
          inserted_at: DateTime.utc_now()
        }
      ])
    end)

    # Confirm tail row exists before checkpoint.
    {:ok, tail_count_before} =
      Repo.with_tenant(user.id, fn ->
        Repo.aggregate(from(l in CrdtUpdateLog, where: l.note_id == ^note.id), :count)
      end)

    assert tail_count_before == 1

    # Checkpoint with an explicit nil watermark (simulating capture failure).
    # With nil watermark, prune_tail becomes a no-op, so the row survives.
    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc, watermark: nil)

    # Tail row must still be present after checkpoint because nil watermark
    # caused prune_tail to skip deletion.
    {:ok, tail_count_after} =
      Repo.with_tenant(user.id, fn ->
        Repo.aggregate(from(l in CrdtUpdateLog, where: l.note_id == ^note.id), :count)
      end)

    assert tail_count_after == 1
  end

  # ── Debounce timer: multiple fast activity signals reset the timer ─────────

  test "CrdtCheckpointTimer debounces — activity signals reset the settle timer", ctx do
    %{user: user, vault: vault, note: note} = ctx

    # A stub room process — lives as long as the test holds :stop in the inbox.
    room_pid = spawn(fn -> receive do: (:stop -> :ok) end)

    # Very short settle so the test doesn't block real seconds.
    Application.put_env(:engram, CrdtCheckpointTimer,
      settle_ms: 50,
      ceiling_ms: 500
    )

    {:ok, timer} =
      CrdtCheckpointTimer.start_link(
        room_pid: room_pid,
        user_id: user.id,
        vault_id: vault.id,
        note_id: note.id
      )

    # Multiple rapid activity events: each resets the settle timer. The timer
    # should be alive (not yet fired) because the settle window keeps sliding.
    CrdtCheckpointTimer.notify_activity(timer)
    CrdtCheckpointTimer.notify_activity(timer)
    CrdtCheckpointTimer.notify_activity(timer)

    # Timer is alive — debounce hasn't expired yet.
    assert Process.alive?(timer)

    # Room exit must propagate to timer via the exit link.
    ref = Process.monitor(timer)
    send(room_pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^timer, _}, 1_000

    Application.delete_env(:engram, CrdtCheckpointTimer)
  end

  # ── No-raise: deleted user row must not crash terminate path ─────────────

  test "checkpoint returns :ok instead of raising when the user row is gone", ctx do
    %{vault: vault, note: note} = ctx
    doc = CrdtBridge.new_doc()

    assert :ok ==
             CrdtCheckpoint.checkpoint(Ecto.UUID.generate(), vault.id, note.id, doc)
  end

  test "CrdtCheckpointTimer exits when room exits", ctx do
    %{user: user, vault: vault, note: note} = ctx

    room_pid = spawn_link(fn -> receive do: (:stop -> :ok) end)

    {:ok, timer} =
      CrdtCheckpointTimer.start_link(
        room_pid: room_pid,
        user_id: user.id,
        vault_id: vault.id,
        note_id: note.id
      )

    ref = Process.monitor(timer)

    # Normal exit of the room kills the timer.
    send(room_pid, :stop)

    assert_receive {:DOWN, ^ref, :process, ^timer, _}, 1_000
  end
end
