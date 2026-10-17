defmodule Engram.Workers.IndexCapMaintenanceTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Workers.IndexCapMaintenance

  # The search-coverage cap is gone, so the worker is a no-op kept only so jobs
  # enqueued by the previous release (or a rolled-back node) complete cleanly
  # instead of failing as an unknown worker.
  test "jobs from the previous release complete as a no-op" do
    user = insert(:user)

    for kind <- ~w(evict_over_cap revoke_dense backfill_slots) do
      assert :ok = perform_job(IndexCapMaintenance, %{user_id: user.id, kind: kind})
    end

    refute_enqueued(worker: Engram.Workers.ReconcileEmbeddings)
  end
end
