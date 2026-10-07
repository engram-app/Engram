defmodule Engram.DataMigrations.CrdtStateSeedTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Crypto, Notes, Vaults}
  alias Engram.DataMigrations.CrdtStateSeed
  alias Engram.Notes.Note
  alias Engram.Workers.{BackfillCrdtState, DataMigrationsRunner}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "CrdtStateSeedTest", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp note!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "B"}, actor: "api")

    note
  end

  defp null_state!(user, note) do
    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id),
          set: [crdt_state_ciphertext: nil, crdt_state_nonce: nil]
        )
      end)
  end

  test "registered with the runner" do
    assert CrdtStateSeed in DataMigrationsRunner.migrations()
    assert {CrdtStateSeed.name(), CrdtStateSeed.version()} == {"crdt_state_seed", 1}
  end

  test "no seedable note: done, nothing enqueued", %{user: u, vault: v} do
    note!(u, v, "a.md")
    assert CrdtStateSeed.run_pass() == :done
    refute_enqueued(worker: BackfillCrdtState)
  end

  test "a seedable note: enqueues its pair and stays open", %{user: u, vault: v} do
    null_state!(u, note!(u, v, "a.md"))
    assert CrdtStateSeed.run_pass() == :more
    assert_enqueued(worker: BackfillCrdtState, args: %{"user_id" => u.id, "vault_id" => v.id})
  end

  test "jobs in flight: open, enqueues nothing more", %{user: u, vault: v} do
    null_state!(u, note!(u, v, "a.md"))
    {:ok, _} = Oban.insert(BackfillCrdtState.new(%{"user_id" => u.id, "vault_id" => v.id}))

    assert CrdtStateSeed.run_pass() == :more
    assert length(all_enqueued(worker: BackfillCrdtState)) == 1
  end

  test "drains to done through the worker", %{user: u, vault: v} do
    null_state!(u, note!(u, v, "a.md"))
    assert CrdtStateSeed.run_pass() == :more

    for job <- all_enqueued(worker: BackfillCrdtState) do
      assert :ok = perform_job(BackfillCrdtState, job.args)
      Repo.delete!(job)
    end

    assert CrdtStateSeed.run_pass() == :done
  end
end
