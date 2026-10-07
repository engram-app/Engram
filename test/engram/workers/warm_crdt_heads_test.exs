defmodule Engram.Workers.WarmCrdtHeadsTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Crypto, Notes, Vaults}
  alias Engram.Vaults.Vault
  alias Engram.Workers.{BackfillCrdtHead, WarmCrdtHeads}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "WarmCrdtHeadsTest", Ecto.UUID.generate())
    # A fresh note starts with a NULL crdt_head.
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A"}, actor: "api")
    %{user: user, vault: vault}
  end

  # Two runs never overlap, but a run that already completed must not swallow
  # the next hourly one.
  test "an incomplete run deduplicates the next enqueue" do
    {:ok, first} = Oban.insert(WarmCrdtHeads.new(%{}))
    {:ok, second} = Oban.insert(WarmCrdtHeads.new(%{}))
    assert second.conflict?
    assert second.id == first.id
  end

  test "a completed run does not deduplicate the next enqueue" do
    {:ok, first} = Oban.insert(WarmCrdtHeads.new(%{}))

    Repo.update_all(from(j in Oban.Job, where: j.id == ^first.id),
      set: [state: "completed", completed_at: DateTime.utc_now()]
    )

    {:ok, second} = Oban.insert(WarmCrdtHeads.new(%{}))
    refute second.conflict?
    assert second.id != first.id
  end

  test "is an hourly cron on the maintenance queue" do
    crontab = Engram.Test.ObanWorkers.crontab()

    assert {"48 * * * *", WarmCrdtHeads} in crontab
    assert WarmCrdtHeads.__opts__()[:queue] == :maintenance
  end

  test "enqueues the head backfill when a NULL-head note exists", %{user: u, vault: v} do
    assert :ok = perform_job(WarmCrdtHeads, %{})
    assert_enqueued(worker: BackfillCrdtHead, args: %{"user_id" => u.id, "vault_id" => v.id})
  end

  test "no-op while a head backfill is in flight", %{user: u, vault: v} do
    {:ok, _} = Oban.insert(BackfillCrdtHead.new(%{"user_id" => u.id, "vault_id" => v.id}))

    assert :ok = perform_job(WarmCrdtHeads, %{})
    assert length(all_enqueued(worker: BackfillCrdtHead)) == 1
  end

  test "no-op when every head is warm", %{user: u, vault: v} do
    assert :ok =
             perform_job(BackfillCrdtHead, %{
               "user_id" => u.id,
               "vault_id" => v.id,
               "cursor" => "00000000-0000-0000-0000-000000000000"
             })

    assert :ok = perform_job(WarmCrdtHeads, %{})
    refute_enqueued(worker: BackfillCrdtHead)
  end

  # The worker discards a deleted vault's job; enqueueing it every hour is waste.
  test "skips a soft-deleted vault", %{vault: v} do
    Repo.update_all(
      from(x in Vault, where: x.id == ^v.id),
      [set: [deleted_at: DateTime.utc_now(:second)]],
      skip_tenant_check: true
    )

    assert :ok = perform_job(WarmCrdtHeads, %{})
    refute_enqueued(worker: BackfillCrdtHead)
  end
end
