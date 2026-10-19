defmodule Engram.Workers.IndexCapMaintenanceTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Workers.IndexCapMaintenance

  # The sweeps themselves are covered in Engram.Indexing.FreeEmbedCapTest.
  # "revoke_dense" is an older release's name for the downgrade sweep.
  test "every kind runs its sweep and kicks the reconcile" do
    user = insert(:user)

    for kind <- ~w(evict_over_cap revoke_dense backfill_slots) do
      assert :ok = perform_job(IndexCapMaintenance, %{user_id: user.id, kind: kind})
    end

    assert_enqueued(worker: Engram.Workers.ReconcileEmbeddings)
  end

  test "enqueue collapses a burst to one job per user and kind" do
    user = insert(:user)

    for _ <- 1..3, do: :ok = IndexCapMaintenance.enqueue(user.id, :backfill_slots)

    assert [_one] = all_enqueued(worker: IndexCapMaintenance)
  end
end
