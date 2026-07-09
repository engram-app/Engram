defmodule Engram.Notes.CrdtCheckpointBackpressureTest do
  # 2026-07-09 pool-exhaustion fix: unbind checkpoints are concurrency-bounded.
  # Under the CheckpointGate limit they run synchronously (timing preserved);
  # over it they overflow to the durable, bounded `crdt_checkpoint` Oban queue.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CheckpointGate, CrdtBridge, CrdtPersistence, CrdtUpdateLog, Note}
  alias Engram.Workers.CheckpointNote

  setup do
    # Start every test with an empty gate, and never leak filled slots into the
    # next test (the gate counter is process-global).
    CheckpointGate.init()
    on_exit(&CheckpointGate.init/0)

    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "BackpressureTest"})
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "p.md", "content" => "before"})
    %{user: user, vault: vault, note: note}
  end

  # Build a doc whose body has been edited to `text`, and return it.
  defp edited_doc(user, note, text) do
    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)
    {:ok, doc} = CrdtBridge.doc_from_state(raw_state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), text)
    doc
  end

  defp state(%{user_id: u, vault_id: v, note_id: n}), do: %{user_id: u, vault_id: v, note_id: n}

  describe "unbind routing" do
    test "under the gate limit: checkpoints synchronously, enqueues no overflow job", ctx do
      %{user: user, vault: vault, note: note} = ctx
      doc = edited_doc(user, note, "before AFTER")

      :ok =
        CrdtPersistence.unbind(
          state(%{user_id: user.id, vault_id: vault.id, note_id: note.id}),
          "d",
          doc
        )

      # Synchronous materialization: notes.content reflects the edit immediately.
      {:ok, fresh} = Notes.get_note(user, vault, "p.md")
      assert fresh.content == "before AFTER"
      # No overflow to Oban on the uncontended path.
      refute_enqueued(worker: CheckpointNote)
    end

    test "over the gate limit: overflows to the Oban queue, no synchronous write", ctx do
      %{user: user, vault: vault, note: note} = ctx
      # Drop the limit to 1 and fill that one slot, so unbind's acquire is
      # refused and takes the overflow path (no real rooms needed). Restore the
      # test default afterward (the setup's on_exit also re-inits the counter).
      prev = Application.get_env(:engram, :checkpoint_inline_limit)
      Application.put_env(:engram, :checkpoint_inline_limit, 1)
      on_exit(fn -> Application.put_env(:engram, :checkpoint_inline_limit, prev) end)
      assert CheckpointGate.acquire() == true

      doc = edited_doc(user, note, "before AFTER")

      :ok =
        CrdtPersistence.unbind(
          state(%{user_id: user.id, vault_id: vault.id, note_id: note.id}),
          "d",
          doc
        )

      # Deferred: a durable job is enqueued for this note, content NOT yet moved.
      assert_enqueued(worker: CheckpointNote, args: %{note_id: note.id})
      {:ok, fresh} = Notes.get_note(user, vault, "p.md")
      assert fresh.content == "before"
    end
  end

  describe "CheckpointNote worker" do
    test "rebuilds the doc from the durable tail-log and materializes the edit", ctx do
      %{user: user, vault: vault, note: note} = ctx

      # Persist the edit as a real encrypted tail-log row (what update_v1 does
      # during live editing), so the worker can reconstruct it from durable state.
      doc = edited_doc(user, note, "before AFTER")
      {:ok, update} = Yex.encode_state_as_update(doc)
      {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state(update, user, note.id)

      Repo.with_tenant(user.id, fn ->
        Repo.insert_all(CrdtUpdateLog, [
          %{
            id: Ecto.UUID.generate(),
            note_id: note.id,
            user_id: user.id,
            vault_id: vault.id,
            update_ciphertext: ct,
            update_nonce: nonce,
            inserted_at: DateTime.utc_now()
          }
        ])
      end)

      assert :ok =
               perform_job(CheckpointNote, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "note_id" => note.id
               })

      {:ok, fresh} = Notes.get_note(user, vault, "p.md")
      assert fresh.content == "before AFTER"
    end

    test "does NOT blank content when the note has no CRDT state (data safety)", ctx do
      %{user: user, vault: vault, note: note} = ctx

      # Strip the note's CRDT state so the doc would rebuild EMPTY. The worker
      # must skip rather than checkpoint an empty doc over notes.content.
      Repo.with_tenant(user.id, fn ->
        from(n in Note, where: n.id == ^note.id)
        |> Repo.update_all(set: [crdt_state_ciphertext: nil, crdt_state_nonce: nil])
      end)

      assert :ok =
               perform_job(CheckpointNote, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "note_id" => note.id
               })

      {:ok, fresh} = Notes.get_note(user, vault, "p.md")
      assert fresh.content == "before"
    end
  end
end
