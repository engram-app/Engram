defmodule Engram.Workers.BackfillCrdtHeadTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.Notes
  alias Engram.Notes.CrdtTransport
  alias Engram.Workers.BackfillCrdtHead

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "BackfillTest", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  describe "fan-out (#2169)" do
    test "enqueue_user queues every vault in one bulk insert", %{user: user, vault: vault} do
      vaults =
        for i <- 1..3 do
          {:ok, v, _} = Engram.Vaults.register_vault(user, "V#{i}", Ecto.UUID.generate())
          v
        end

      assert {:ok, 1} =
               Engram.ObanInsertCount.count(fn -> BackfillCrdtHead.enqueue_user(user.id) end)

      queued = all_enqueued(worker: BackfillCrdtHead) |> Enum.map(& &1.args["vault_id"])
      assert Enum.sort(queued) == Enum.sort([vault.id | Enum.map(vaults, & &1.id)])
    end

    test "enqueue_all queues every (user, vault) in one bulk insert", %{user: user, vault: vault} do
      note = fn u, v, path ->
        {:ok, _} =
          Notes.upsert_note(u, v, %{path: path, content: "# x", mtime: 1.0}, actor: "api")
      end

      note.(user, vault, "A/a.md")

      for i <- 1..2 do
        other = insert(:user)
        insert(:user_limit_override, user: other, key: "vaults_cap", value: %{"v" => -1})
        {:ok, other} = Engram.Crypto.ensure_user_dek(other)
        {:ok, ov, _} = Engram.Vaults.register_vault(other, "O#{i}", Ecto.UUID.generate())
        note.(other, ov, "B/b.md")
      end

      assert {3, 1} = Engram.ObanInsertCount.count(fn -> BackfillCrdtHead.enqueue_all() end)
      assert length(all_enqueued(worker: BackfillCrdtHead)) == 3
    end
  end

  describe "perform/1" do
    test "populates a NULL crdt_head to match the authoritative read", %{user: user, vault: vault} do
      {:ok, a} =
        Notes.upsert_note(user, vault, %{path: "B/A.md", content: "# A", mtime: 1_000.0},
          actor: "api"
        )

      {:ok, b} =
        Notes.upsert_note(user, vault, %{path: "B/B.md", content: "# B", mtime: 1_000.0},
          actor: "api"
        )

      {:ok, a0} = Notes.get_note_by_id(user, vault, a.id)
      assert is_nil(a0.crdt_head), "a freshly-inserted note starts NULL"

      assert :ok =
               perform_job(BackfillCrdtHead, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "cursor" => "00000000-0000-0000-0000-000000000000"
               })

      {:ok, a1} = Notes.get_note_by_id(user, vault, a.id)
      {:ok, b1} = Notes.get_note_by_id(user, vault, b.id)
      refute is_nil(a1.crdt_head)
      refute is_nil(b1.crdt_head)

      {:ok, %{head: rd}} = CrdtTransport.read_delta(user, vault, a.id, nil)
      assert a1.crdt_head == rd, "backfilled head must equal the authoritative read_delta head"
    end

    test "enqueue_all enqueues one job per (user, vault) with a NULL-head note",
         %{user: user, vault: vault} do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{path: "B/C.md", content: "# C", mtime: 1_000.0},
          actor: "api"
        )

      assert BackfillCrdtHead.enqueue_all() >= 1

      assert_enqueued(
        worker: BackfillCrdtHead,
        args: %{"user_id" => user.id, "vault_id" => vault.id}
      )
    end

    test "a full batch re-enqueues a successor at the last-processed cursor", %{
      user: user,
      vault: vault
    } do
      # Force a batch size of 1 so two notes span two batches without inserting 101.
      Application.put_env(:engram, :crdt_head_backfill_batch_size, 1)
      on_exit(fn -> Application.delete_env(:engram, :crdt_head_backfill_batch_size) end)

      # uuidv7 ids are time-ordered, so `a` (created first) has the smaller id and
      # is the sole member of the first (limit-1) batch.
      {:ok, a} =
        Notes.upsert_note(user, vault, %{path: "B/a.md", content: "# A", mtime: 1_000.0},
          actor: "api"
        )

      {:ok, _b} =
        Notes.upsert_note(user, vault, %{path: "B/b.md", content: "# B", mtime: 1_000.0},
          actor: "api"
        )

      assert :ok =
               perform_job(BackfillCrdtHead, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "cursor" => "00000000-0000-0000-0000-000000000000"
               })

      # Full batch (length == limit) → a successor job at cursor = last id processed.
      assert_enqueued(
        worker: BackfillCrdtHead,
        args: %{"user_id" => user.id, "vault_id" => vault.id, "cursor" => a.id}
      )
    end

    # One note whose state will not decrypt must not raise out of the batch:
    # that strands every later note behind a retrying job, and the in-flight
    # guard in WarmCrdtHeads then stops all re-warming.
    test "an unreadable note is skipped and later notes still get heads", %{
      user: user,
      vault: vault
    } do
      {:ok, bad} =
        Notes.upsert_note(user, vault, %{path: "B/bad.md", content: "# X", mtime: 1_000.0},
          actor: "api"
        )

      {:ok, good} =
        Notes.upsert_note(user, vault, %{path: "B/good.md", content: "# Y", mtime: 1_000.0},
          actor: "api"
        )

      {:ok, _} =
        Engram.Repo.with_tenant(user.id, fn ->
          Engram.Fixtures.write_note_body!(bad.id,
            crdt_state_ciphertext: :crypto.strong_rand_bytes(48),
            crdt_state_nonce: :crypto.strong_rand_bytes(12)
          )
        end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   perform_job(BackfillCrdtHead, %{
                     "user_id" => user.id,
                     "vault_id" => vault.id,
                     "cursor" => "00000000-0000-0000-0000-000000000000"
                   })
        end)

      assert log =~ bad.id
      {:ok, good1} = Notes.get_note_by_id(user, vault, good.id)
      refute is_nil(good1.crdt_head)
    end

    test "snoozes while a per-user DEK rotation is in progress", %{user: user, vault: vault} do
      Repo.update!(Ecto.Changeset.change(user, dek_rotation_locked_at: DateTime.utc_now()))

      assert {:snooze, 60} =
               perform_job(BackfillCrdtHead, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "cursor" => "00000000-0000-0000-0000-000000000000"
               })
    end

    test "discards when the vault no longer exists", %{user: user} do
      assert {:discard, :vault_deleted} =
               perform_job(BackfillCrdtHead, %{
                 "user_id" => user.id,
                 "vault_id" => Ecto.UUID.generate(),
                 "cursor" => "00000000-0000-0000-0000-000000000000"
               })
    end

    # NOTE: this exercises RotationGate.check's user-not-found arm (which runs
    # first), not run/3's own nil guard — both return the same discard reason.
    test "discards when the user no longer exists", %{vault: vault} do
      assert {:discard, :user_deleted} =
               perform_job(BackfillCrdtHead, %{
                 "user_id" => Ecto.UUID.generate(),
                 "vault_id" => vault.id,
                 "cursor" => "00000000-0000-0000-0000-000000000000"
               })
    end

    test "enqueue_all fans out across tenants (one job per distinct user/vault)", %{
      user: user,
      vault: vault
    } do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{path: "B/x.md", content: "# X", mtime: 1_000.0},
          actor: "api"
        )

      other = insert(:user)
      insert(:user_limit_override, user: other, key: "vaults_cap", value: %{"v" => -1})
      {:ok, other} = Engram.Crypto.ensure_user_dek(other)

      {:ok, other_vault, _} =
        Engram.Vaults.register_vault(other, "OtherVault", Ecto.UUID.generate())

      {:ok, _} =
        Notes.upsert_note(other, other_vault, %{path: "B/y.md", content: "# Y", mtime: 1.0},
          actor: "api"
        )

      assert BackfillCrdtHead.enqueue_all() == 2

      assert_enqueued(
        worker: BackfillCrdtHead,
        args: %{"user_id" => user.id, "vault_id" => vault.id}
      )

      assert_enqueued(
        worker: BackfillCrdtHead,
        args: %{"user_id" => other.id, "vault_id" => other_vault.id}
      )
    end
  end

  # R8 N+1: the manifest serves the body row's head (`NoteBody`), so warming
  # must judge "NULL" by the body row too, not by the `notes` copy. A split
  # brain (a raw write to one side, which nothing copies) tells them apart.
  describe "judges the head by the body row" do
    setup %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{path: "H.md", content: "# H", mtime: 1.0}, actor: "api")

      :ok = warm!(user, vault)
      assert is_binary(notes_head(note)) and is_binary(body_head(note))
      %{note: note}
    end

    test "enqueue_all queues a note whose body head is NULL", ctx do
      raw!("UPDATE note_bodies SET crdt_head = NULL WHERE note_id = $1", ctx.note)

      BackfillCrdtHead.enqueue_all()

      assert_enqueued(
        worker: BackfillCrdtHead,
        args: %{"user_id" => ctx.user.id, "vault_id" => ctx.vault.id}
      )
    end

    # A split either way heals on the next warm (with the copy trigger gone,
    # nothing else would). Red on 38a2a1f1c: the batch skipped (notes NULL),
    # and a lost compare-and-set left the body NULL (body NULL).
    test "a split with the notes head NULL heals on the next warm", ctx do
      raw!("UPDATE notes SET crdt_head = NULL WHERE id = $1", ctx.note)

      :ok = warm!(ctx.user, ctx.vault)

      assert is_binary(notes_head(ctx.note))
      assert in_step?(ctx.note)
    end

    test "a split with the body head NULL heals on the next warm", ctx do
      raw!("UPDATE note_bodies SET crdt_head = NULL WHERE note_id = $1", ctx.note)

      :ok = warm!(ctx.user, ctx.vault)

      assert is_binary(body_head(ctx.note))
      assert in_step?(ctx.note)
    end

    # Red on 38a2a1f1c: the append's reset read only the notes copy, so a
    # body head over a NULL notes head was served as current after the doc
    # moved on.
    test "an append resets a body head the notes copy no longer holds", ctx do
      raw!("UPDATE notes SET crdt_head = NULL WHERE id = $1", ctx.note)

      {:ok, %{state: upd}} = Engram.Notes.CrdtBridge.merge_plaintext(nil, "moved on")
      doc = Engram.Notes.CrdtBridge.new_doc()
      :ok = Yex.apply_update(doc, upd)
      st = %{user_id: ctx.user.id, vault_id: ctx.vault.id, note_id: ctx.note.id}
      _ = Engram.Notes.CrdtPersistence.update_v1(st, upd, ctx.note.id, doc)

      assert is_nil(body_head(ctx.note))
    end
  end

  defp warm!(user, vault) do
    perform_job(BackfillCrdtHead, %{
      "user_id" => user.id,
      "vault_id" => vault.id,
      "cursor" => "00000000-0000-0000-0000-000000000000"
    })
  end

  defp raw!(sql, note), do: Engram.Repo.query!(sql, [Ecto.UUID.dump!(note.id)])

  defp notes_head(note),
    do: one!("SELECT crdt_head FROM notes WHERE id = $1", note)

  defp body_head(note),
    do: one!("SELECT crdt_head FROM note_bodies WHERE note_id = $1", note)

  defp in_step?(note), do: Engram.Fixtures.note_body_divergence(note.user_id) == []

  defp one!(sql, note) do
    %{rows: [[v]]} = raw!(sql, note)
    v
  end
end
