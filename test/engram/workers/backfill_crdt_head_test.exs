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

    test "discards when the user no longer exists", %{vault: vault} do
      assert {:discard, :user_deleted} =
               perform_job(BackfillCrdtHead, %{
                 "user_id" => Ecto.UUID.generate(),
                 "vault_id" => vault.id,
                 "cursor" => "00000000-0000-0000-0000-000000000000"
               })
    end
  end
end
