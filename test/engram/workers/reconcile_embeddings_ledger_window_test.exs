defmodule Engram.Workers.ReconcileEmbeddingsLedgerWindowTest do
  # The daily Voyage ceilings read a "rolling day" back from RebuildStaleNote
  # rows in oban_jobs. Oban's pruner deletes completed jobs, so the ceiling
  # can only under-count if the pruner forgets a job while it is still inside
  # that day. This pins the two facts that make that impossible.
  use Engram.DataCase, async: false

  alias Engram.Workers.{RebuildStaleNote, ReconcileEmbeddings}

  test "the pruner keeps completed jobs at least as long as the ledger looks back" do
    plugins = :engram |> Application.fetch_env!(Oban) |> Keyword.fetch!(:plugins)
    {Oban.Plugins.Pruner, opts} = Enum.find(plugins, &match?({Oban.Plugins.Pruner, _}, &1))

    assert Keyword.fetch!(opts, :max_age) >= ReconcileEmbeddings.ledger_window_seconds()
  end

  test "a completed job still inside the window survives a prune, even with build-to-insert skew" do
    window = ReconcileEmbeddings.ledger_window_seconds()
    now = DateTime.utc_now()
    # Inside the window by 5 s; scheduled_at 200 ms BEFORE inserted_at, the
    # order a real insert produces (the changeset is built, then inserted).
    inserted = DateTime.add(now, -window + 5, :second)
    scheduled = DateTime.add(inserted, -200, :millisecond)

    {:ok, job} =
      %{note_id: Ecto.UUID.generate(), user_id: Ecto.UUID.generate(), budget_tokens: 1}
      |> RebuildStaleNote.new()
      |> Oban.insert()

    {1, _} =
      Repo.update_all(
        from(j in Oban.Job, where: j.id == ^job.id),
        [set: [state: "completed", inserted_at: inserted, scheduled_at: scheduled]],
        skip_tenant_check: true
      )

    {:ok, _} =
      Oban.Engines.Basic.prune_jobs(Oban.config(), Oban.Job, max_age: window, limit: 1_000)

    assert Repo.get(Oban.Job, job.id, skip_tenant_check: true)

    # And the pruner does delete once the job has left the window.
    {1, _} =
      Repo.update_all(
        from(j in Oban.Job, where: j.id == ^job.id),
        [set: [scheduled_at: DateTime.add(now, -window - 60, :second)]],
        skip_tenant_check: true
      )

    {:ok, _} =
      Oban.Engines.Basic.prune_jobs(Oban.config(), Oban.Job, max_age: window, limit: 1_000)

    refute Repo.get(Oban.Job, job.id, skip_tenant_check: true)
  end
end
