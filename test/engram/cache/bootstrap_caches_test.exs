defmodule Engram.Cache.BootstrapCachesTest do
  # Not async: the caches and the query recorder's telemetry handler are global.
  use Engram.DataCase, async: false

  alias Engram.Indexing.IndexCap
  alias Engram.Notes
  alias Engram.Onboarding
  alias Engram.QueryRecorder
  alias Engram.Vaults

  setup do
    Engram.DataCase.clear_request_caches()
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    insert(:user_limit_override, user: user, key: "indexed_notes_cap", value: %{"v" => 100})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "Counts", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  # What the AFTER-write trigger's pg_notify does on every node in prod; the
  # sandbox never commits, so tests deliver it by hand.
  defp notify(channel, payload) do
    send(Engram.Cache.Server, {:notification, self(), make_ref(), channel, payload})
    _ = :sys.get_state(Engram.Cache.Server)
    :ok
  end

  defp db_queries(fun) do
    {_, qs} = QueryRecorder.record(fun)
    Enum.reject(qs, &(&1.source in ["tenant_txn", "tenant_enter", "tenant_exit_sandbox"]))
  end

  defp create!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "# x", "mtime" => 1.0},
        actor: "api"
      )

    note
  end

  describe "onboarding actions" do
    test "cached; record_action evicts it on the writing node", %{user: user} do
      before = Onboarding.list_actions(user.id)
      refute "tour_completed" in before
      assert db_queries(fn -> Onboarding.list_actions(user.id) end) == []

      :ok = Onboarding.record_action(user.id, "tour_completed")
      assert "tour_completed" in Onboarding.list_actions(user.id)
    end
  end

  describe "vault count" do
    test "count_for reads the cached vault list", %{user: user} do
      assert Vaults.count_for(user) == 1
      assert db_queries(fn -> Vaults.count_for(user) end) == []

      {:ok, _, _} = Vaults.register_vault(user, "Second", Ecto.UUID.generate())
      assert Vaults.count_for(user) == 2
    end
  end

  describe "live note count (IndexCap.counts)" do
    test "cached; a create and a delete evict it on the writing node", %{user: user, vault: v} do
      assert IndexCap.counts(user).total == 0
      assert db_queries(fn -> IndexCap.counts(user) end) == []

      create!(user, v, "A.md")
      assert IndexCap.counts(user).total == 1

      :ok = Notes.delete_note(user, v, "A.md")
      assert IndexCap.counts(user).total == 0
    end

    test "a note_counts_changed notification evicts it (raw writers)", %{user: user, vault: v} do
      assert IndexCap.counts(user).total == 0
      insert(:note, user: user, vault: v)
      assert IndexCap.counts(user).total == 0
      notify("note_counts_changed", user.id)
      assert IndexCap.counts(user).total == 1
    end
  end

  describe "vault content counts" do
    test "cached; a create and a delete evict them on the writing node", %{user: user, vault: v} do
      assert %{notes: 0} = Vaults.content_counts(user, v.id)
      assert db_queries(fn -> Vaults.content_counts(user, v.id) end) == []

      create!(user, v, "A.md")
      assert %{notes: 1} = Vaults.content_counts(user, v.id)

      :ok = Notes.delete_note(user, v, "A.md")
      assert %{notes: 0} = Vaults.content_counts(user, v.id)
    end

    test "a note_counts_changed notification evicts them (raw writers)", %{user: user, vault: v} do
      assert %{notes: 0, attachments: 0} = Vaults.content_counts(user, v.id)
      insert(:note, user: user, vault: v)
      notify("note_counts_changed", user.id)
      assert %{notes: 1} = Vaults.content_counts(user, v.id)
    end

    test "keyed by owner: another user's counts never answer", %{user: user, vault: v} do
      create!(user, v, "A.md")
      assert %{notes: 1} = Vaults.content_counts(user, v.id)

      {:ok, other} = Engram.Crypto.ensure_user_dek(insert(:user))
      assert Vaults.content_counts(other, v.id) == %{notes: 0, attachments: 0, populated: false}
    end
  end
end
