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

  # ── deliver-out gap: a web-editor edit (CRDT checkpoint) must reach clients ─
  # that are not actively enrolled in the note's room (e.g. Obsidian). REST/MCP
  # writes announce via CrdtDeliver; the checkpoint is the ONLY path that
  # persists a web edit and did not announce, so the edit never reached Obsidian
  # live nor on the next discovery. The checkpoint must announce crdt_doc_ready
  # (doc_id = note_id) on content change so a lazily-enrolled client pulls it.

  test "checkpoint announces crdt_doc_ready on content change so obsidian pulls the web edit",
       ctx do
    %{user: user, vault: vault, note: note} = ctx
    EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")

    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)
    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)

    :ok =
      CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "before EDITED")

    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    assert_receive %Phoenix.Socket.Broadcast{
      event: "crdt_doc_ready",
      payload: %{"doc_id" => doc_id}
    }

    assert doc_id == note.id
  end

  test "checkpoint does NOT announce when text is unchanged (compaction — no re-pull spam)",
       ctx do
    %{user: user, vault: vault, note: note} = ctx
    EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")

    # Rebuild the doc from stored state WITHOUT editing the text — this is the
    # idle compaction path (hash-equal), which must not touch seq/content and
    # must not announce.
    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)
    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)

    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    refute_receive %Phoenix.Socket.Broadcast{event: "crdt_doc_ready"}
  end

  # ── #902 revert gap: checkpoint must not clobber a newer committed write ───

  test "checkpoint does NOT revert a REST write that committed after the doc snapshot", ctx do
    %{user: user, vault: vault, note: note} = ctx

    # The live room holds a doc that still projects the ORIGINAL "before" content,
    # captured at the note's current version. This is the stale-room snapshot.
    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)
    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)
    captured_version = raw_note.version

    # A concurrent REST write commits NEW content and bumps the row version —
    # this is the deliver_out gap: it landed after the doc snapshot was taken.
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "p.md", "content" => "committed after"})

    # The debounced checkpoint now fires with the stale doc. Fenced on the
    # captured version, it must ABORT rather than overwrite the newer row.
    :ok =
      CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc,
        captured_version: captured_version
      )

    {:ok, fresh} = Notes.get_note(user, vault, "p.md")

    assert fresh.content == "committed after",
           "checkpoint reverted a committed REST write (the #902 gap)"
  end

  # ── Phase 0 (identity-as-CRDT): checkpoint must be MONOTONE ─────────────────
  # The version fence only aborts when the row moved AFTER capture. A room whose
  # doc missed a deliver_out (decrypt blip, KMS outage) is behind writes that
  # committed BEFORE capture: the fence passes and the stale doc used to
  # overwrite both notes.content AND crdt_state, destroying the REST/MCP write
  # entirely (prod incident 2026-07-07: MCP work-log appends erased on plugin
  # reconnect). Fix: checkpoint folds the row's stored state into the doc state
  # (Yjs union, same lineage as deliver_out) before materializing — the output
  # can only grow, never regress, regardless of what the room missed.

  test "checkpoint UNIONS the row's stored state — a stale room doc cannot erase a REST write",
       ctx do
    %{user: user, vault: vault, note: note} = ctx

    # The room doc is built from the ORIGINAL state and diverges with a live
    # edit — but it never receives the REST write below (a missed deliver_out).
    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)
    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "before EDIT")

    # REST/MCP write commits new merged content + state, bumping the version —
    # BEFORE the checkpoint captures anything, so no fence can catch this.
    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "p.md", "content" => "before APPEND"})

    # Room exits (unbind path: no captured_version). Today this blindly writes
    # "before EDIT" over "before APPEND" — content AND crdt_state regress.
    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    {:ok, fresh} = Notes.get_note(user, vault, "p.md")

    assert fresh.content =~ "APPEND",
           "checkpoint erased a committed REST write the room doc never saw"

    assert fresh.content =~ "EDIT",
           "checkpoint lost the room's own live edit"

    # The persisted CRDT state must also carry the union: rebuilding a doc from
    # it must project the merged text (the row state is the durable truth the
    # next bind hydrates from — content alone converging is not enough).
    {:ok, after_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, after_state} = Crypto.decrypt_crdt_state(after_note, user)
    {:ok, rebuilt} = CrdtBridge.doc_from_state(after_state)
    rebuilt_text = CrdtBridge.text_of(rebuilt)
    assert rebuilt_text =~ "APPEND"
    assert rebuilt_text =~ "EDIT"
  end

  test "checkpoint ABORTS (row untouched) when the row's stored state cannot be read", ctx do
    %{user: user, vault: vault, note: note} = ctx

    # Divergent room doc, as above.
    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)
    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "before EDIT")

    # Corrupt the stored state so it cannot be decrypted: the checkpoint can no
    # longer prove its write is a superset of the durable truth, so it must not
    # write at all (unreadable ≠ absent — overwriting could destroy data).
    Repo.with_tenant(user.id, fn ->
      Repo.update_all(from(n in Note, where: n.id == ^note.id),
        set: [crdt_state_ciphertext: <<0, 1, 2, 3>>, crdt_state_nonce: <<0::96>>]
      )
    end)

    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    {:ok, after_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    assert after_note.version == note.version, "checkpoint wrote despite unreadable stored state"

    assert after_note.crdt_state_ciphertext == <<0, 1, 2, 3>>,
           "checkpoint replaced a stored state it could not read"
  end

  # ── /changes feed integrity: checkpoint must advance updated_at ────────────

  test "checkpoint advances updated_at so the /changes timestamp feed sees the edit", ctx do
    %{user: user, vault: vault, note: note} = ctx

    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    before_updated_at = raw_note.updated_at

    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)
    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)

    :ok =
      CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "before CHANGED")

    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    {:ok, fresh} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)

    # The content-write branch persists via update_all, which does NOT
    # auto-manage timestamps. If updated_at is not set explicitly, a CRDT edit
    # is invisible to GET /api/notes/changes (it filters + orders on updated_at)
    # — silent non-propagation of committed CRDT content.
    assert DateTime.compare(fresh.updated_at, before_updated_at) == :gt,
           "checkpoint must bump updated_at or the /changes timestamp feed silently drops the edit"
  end

  # ── Fence success path: captured_version == current still writes ───────────

  test "checkpoint with captured_version matching the current row writes, bumps version, prunes",
       ctx do
    %{user: user, vault: vault, note: note} = ctx

    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    captured_version = raw_note.version

    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)
    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)

    :ok =
      CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "before FENCED")

    # Seed a tail row to prove the success path still prunes.
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

    :ok =
      CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc,
        captured_version: captured_version
      )

    # Version matched → the CAS wrote (did not spuriously abort on equal versions).
    {:ok, fresh} = Notes.get_note(user, vault, "p.md")
    assert fresh.content == "before FENCED"
    assert fresh.version == captured_version + 1

    # Success path prunes the consumed tail.
    {:ok, tail_after} =
      Repo.with_tenant(user.id, fn ->
        Repo.aggregate(from(l in CrdtUpdateLog, where: l.note_id == ^note.id), :count)
      end)

    assert tail_after == 0
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

  # ── OKF frontmatter integrity: live edits must re-run extraction ───────────
  # Finding 1 (critical, whole-branch review): the changed-text branch
  # re-materialized content/title/tags/content_hash + phase-B fields, but
  # never re-ran OKF extraction, so a live-editor frontmatter edit persisted
  # content while type_ciphertext/type_hmac/fm_timestamp/fm_created kept
  # stale values.

  @okf_content """
  ---
  type: Playbook
  description: Freshness alert triage.
  resource: https://x.test/dash
  timestamp: 2026-05-28T14:30:00Z
  created: 2026-05-01
  ---
  body
  """

  test "checkpoint re-extracts OKF fields when a live edit changes frontmatter type", ctx do
    %{user: user, vault: vault} = ctx

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "okf/change.md", "content" => @okf_content})

    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)
    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)

    new_content = String.replace(@okf_content, "type: Playbook", "type: Reference")

    # Frontmatter lives in a separate Y.Map from the body Y.Text, so a bare
    # `diff_into_text` only rewrites the body. A frontmatter-changing edit
    # must go through `ingest_plaintext` (what the live editor round-trips
    # through) to land the new `type:` key.
    :ok = CrdtBridge.ingest_plaintext(doc, new_content)

    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    {:ok, fresh} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    assert fresh.type_hmac == Crypto.hmac_field(filter_key, "reference")
  end

  # ── #954: deleted note/user must be a QUIET skip, not a raise-noise storm ──
  # Vault deletion (force-purge) hard-deletes rows while rooms live on; each
  # room tick/exit then raised Ecto.NoResultsError — caught, but logged at
  # error (Sentry + Loki storms, 2026-07-07 19:03). A missing row is an
  # EXPECTED lifecycle state, not an error.

  test "checkpoint on a DELETED note skips quietly — no raise, no error log", ctx do
    %{user: user, vault: vault, note: note} = ctx

    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)
    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)

    # Hard-delete the row out from under the live room (the force-purge shape).
    Repo.with_tenant(user.id, fn ->
      Repo.delete_all(from(l in CrdtUpdateLog, where: l.note_id == ^note.id))
      Repo.delete_all(from(n in Note, where: n.id == ^note.id))
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)
      end)

    refute log =~ "checkpoint raised", "deleted note must not raise: #{log}"
    refute log =~ "[error]", "deleted note is expected lifecycle, not an error: #{log}"
  end

  test "checkpoint on a DELETED user skips quietly — no raise, no error log", ctx do
    %{user: user, vault: vault, note: note} = ctx

    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)
    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)

    # A user id that never existed models the deleted-user shape without
    # fighting FK cascades (matches the existing user-row-gone test).
    gone_user_id = Ecto.UUID.generate()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = CrdtCheckpoint.checkpoint(gone_user_id, vault.id, note.id, doc)
      end)

    refute log =~ "checkpoint raised", "deleted user must not raise: #{log}"
    refute log =~ "[error]", "deleted user is expected lifecycle, not an error: #{log}"
  end

  test "checkpoint nulls OKF fields when a live edit removes frontmatter", ctx do
    %{user: user, vault: vault} = ctx

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "okf/remove.md", "content" => @okf_content})

    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)
    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)

    :ok = CrdtBridge.ingest_plaintext(doc, "just body\n")

    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    {:ok, fresh} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    assert is_nil(fresh.type_hmac)
    assert is_nil(fresh.type_ciphertext)
    assert is_nil(fresh.fm_timestamp)
    assert is_nil(fresh.fm_created)
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
