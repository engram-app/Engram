defmodule Engram.DataMigrations.PersonOriginBackfillTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.DataMigrations.PersonOriginBackfill
  alias Engram.Workers.DataMigrationsRunner
  alias Engram.Workers.PersonOriginSync

  @keys [:posthog_key, :posthog_erasure_api_key, :posthog_project_id]

  setup do
    prior = Map.new(@keys, &{&1, Application.get_env(:engram, &1)})
    on_exit(fn -> Enum.each(prior, fn {k, v} -> Application.put_env(:engram, k, v) end) end)
    :ok
  end

  defp configure, do: Enum.each(@keys, &Application.put_env(:engram, &1, "test"))

  defp backfill_jobs, do: all_enqueued(worker: PersonOriginSync)

  defp set_state(job, state) do
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
  end

  test "registered with the runner" do
    assert PersonOriginBackfill in DataMigrationsRunner.migrations()
  end

  test "disabled without PostHog read config" do
    Enum.each(@keys, &Application.put_env(:engram, &1, nil))
    refute PersonOriginBackfill.enabled?()
  end

  test "enabled with PostHog read config" do
    configure()
    assert PersonOriginBackfill.enabled?()
  end

  test "enqueues exactly one chain when none exists, none while it is in flight" do
    assert {:more, _} = PersonOriginBackfill.run_pass()
    assert {:more, running: true} = PersonOriginBackfill.run_pass()
    assert [%{args: %{"backfill" => true}}] = backfill_jobs()
  end

  test "a later batch in flight blocks a second chain" do
    {:ok, _} = PersonOriginSync.backfill()
    Oban.insert!(PersonOriginSync.new(%{"backfill" => true, "after" => Ecto.UUID.generate()}))
    {:ok, head} = PersonOriginSync.backfill()
    set_state(head, "completed")

    assert {:more, running: true} = PersonOriginBackfill.run_pass()
    assert length(backfill_jobs()) == 2
  end

  test "a single-user job is not a backfill chain" do
    {:ok, _} = Oban.insert(PersonOriginSync.new(%{"user_id" => Ecto.UUID.generate()}))
    assert {:more, enqueued: true} = PersonOriginBackfill.run_pass()
  end

  test "done once the newest batch completed, and stays done" do
    {:ok, job} = PersonOriginSync.backfill()
    set_state(job, "completed")

    assert :done = PersonOriginBackfill.run_pass()
    assert :done = PersonOriginBackfill.run_pass()
    assert [] = backfill_jobs()
  end

  test "a discarded newest batch restarts the chain" do
    {:ok, job} = PersonOriginSync.backfill()
    set_state(job, "discarded")

    assert {:more, enqueued: true} = PersonOriginBackfill.run_pass()
    assert [%{args: %{"backfill" => true}}] = backfill_jobs()
  end
end
