defmodule Engram.Workers.BackfillCrdtHeadTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Notes
  alias Engram.Notes.CrdtTransport
  alias Engram.Workers.BackfillCrdtHead

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "BackfillTest"})
    %{user: user, vault: vault}
  end

  describe "perform/1" do
    test "populates a NULL crdt_head to match the authoritative read", %{user: user, vault: vault} do
      {:ok, a} = Notes.upsert_note(user, vault, %{path: "B/A.md", content: "# A", mtime: 1_000.0})
      {:ok, b} = Notes.upsert_note(user, vault, %{path: "B/B.md", content: "# B", mtime: 1_000.0})

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
      {:ok, _} = Notes.upsert_note(user, vault, %{path: "B/C.md", content: "# C", mtime: 1_000.0})

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
      {:ok, a} = Notes.upsert_note(user, vault, %{path: "B/a.md", content: "# A", mtime: 1_000.0})

      {:ok, _b} =
        Notes.upsert_note(user, vault, %{path: "B/b.md", content: "# B", mtime: 1_000.0})

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
      {:ok, _} = Notes.upsert_note(user, vault, %{path: "B/x.md", content: "# X", mtime: 1_000.0})

      other = insert(:user)
      insert(:user_limit_override, user: other, key: "vaults_cap", value: %{"v" => -1})
      {:ok, other} = Engram.Crypto.ensure_user_dek(other)
      {:ok, other_vault} = Engram.Vaults.create_vault(other, %{name: "OtherVault"})

      {:ok, _} =
        Notes.upsert_note(other, other_vault, %{path: "B/y.md", content: "# Y", mtime: 1.0})

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
end
