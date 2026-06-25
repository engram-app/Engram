defmodule Engram.Notes.CrdtEmbedCoalescingTest do
  @moduledoc """
  Regression guard: per-keystroke CRDT update_v1 calls must NEVER enqueue an
  EmbedNote job. Embeds fire only on debounced checkpoints (when content_hash
  changes). This ensures a burst of N Yjs updates triggers at most ONE Voyage
  call, not N — the amplification guard for the embedding pipeline.
  """

  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.{Crypto, Notes, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, CrdtPersistence, Note}
  alias Engram.Workers.EmbedNote

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "CrdtEmbedCoalescingTest"})
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "coalesce.md", "content" => "base"})
    %{user: user, vault: vault, note: note}
  end

  # ── Core coalescing guard ─────────────────────────────────────────────────

  test "N successive update_v1 calls enqueue zero embeds", ctx do
    %{user: user, vault: vault, note: note} = ctx

    # Baseline: upsert_note already enqueued one EmbedNote job in setup.
    # Capture it now so subsequent assertions measure only the update_v1 calls.
    baseline = length(all_enqueued(worker: EmbedNote))

    # Simulate 5 rapid Yjs update_v1 calls (per-keystroke hot path).
    # Each writes an encrypted tail-log row only — no embed must be enqueued.
    persistence_state = %{user_id: user.id, vault_id: vault.id, note_id: note.id, user: user}

    for n <- 1..5 do
      {:ok, %{state: update_bin}} = CrdtBridge.merge_plaintext(nil, "edit #{n}")
      CrdtPersistence.update_v1(persistence_state, update_bin, note.id, CrdtBridge.new_doc())
    end

    # Assert: no new embed jobs from update_v1 calls.
    assert length(all_enqueued(worker: EmbedNote)) == baseline,
           "update_v1 must not enqueue EmbedNote; got #{length(all_enqueued(worker: EmbedNote)) - baseline} extra job(s)"
  end

  test "checkpoint with changed content fires an embed (not suppressed by update_v1 calls)",
       ctx do
    %{user: user, vault: vault, note: note} = ctx

    # Simulate N update_v1 calls first (the burst of keystrokes).
    persistence_state = %{user_id: user.id, vault_id: vault.id, note_id: note.id, user: user}

    for n <- 1..5 do
      {:ok, %{state: update_bin}} = CrdtBridge.merge_plaintext(nil, "edit #{n}")
      CrdtPersistence.update_v1(persistence_state, update_bin, note.id, CrdtBridge.new_doc())
    end

    # Checkpoint with changed content. Load the note's actual CRDT state so the
    # doc reflects the real persisted snapshot, then apply the new text on top.
    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)
    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "checkpointed")
    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    # A debounced embed job for this note must exist (new or coalesced into the
    # one upsert_note enqueued — Oban replace: [:scheduled_at] dedup means the
    # job count may not change, but the job must be present).
    assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
  end

  test "checkpoint with unchanged content enqueues no additional embed", ctx do
    %{user: user, vault: vault, note: note} = ctx

    baseline = length(all_enqueued(worker: EmbedNote))

    # Checkpoint with the same content as setup ("base") — no hash change, no new embed.
    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)
    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "base")
    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    assert length(all_enqueued(worker: EmbedNote)) == baseline,
           "checkpoint with unchanged content must not enqueue EmbedNote"
  end
end
