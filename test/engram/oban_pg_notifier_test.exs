defmodule Engram.ObanPgNotifierTest do
  # Guard: a clustered node uses `Oban.Notifiers.PG`, and a job inserted
  # inside a write transaction still wakes the worker once it commits.
  #
  # `Oban.Notifiers.Postgres` holds one LISTEN connection per node and
  # delivers on commit. PG costs no connection but sends at once, so a job
  # inserted inside `Repo.with_tenant/2` (most enqueues: `Notes.ContentCommit`
  # and friends) wakes a producer that cannot see the row yet; it would then
  # wait for the leader's next stager tick (5s). `Engram.Oban.SafeEngine`
  # re-sends the insert notification after commit. Nothing is lost either
  # way: the job is a row, and the stager notifies every queue with available
  # jobs on each tick.
  use Engram.DataCase, async: false

  @runtime Path.join(__DIR__, "../../config/runtime.exs")

  setup do
    name = __MODULE__.Oban

    start_supervised!(
      {Oban,
       name: name,
       repo: Engram.Repo,
       engine: Engram.Oban.SafeEngine,
       notifier: Oban.Notifiers.PG,
       queues: false,
       plugins: false,
       stage_interval: :infinity}
    )

    :ok = Oban.Notifier.listen(name, :insert)
    %{oban: name, user: insert(:user)}
  end

  defp job, do: Oban.Job.new(%{}, worker: "Engram.NoSuchWorker", queue: "pg_notifier_test")

  test "a job inserted in a tenant transaction is re-announced after commit", ctx do
    {:ok, _} =
      Engram.Repo.with_tenant(ctx.user.id, fn ->
        {:ok, _} = Oban.insert(ctx.oban, job())
        # Oban's own, sent before the row is visible to anyone else.
        assert_receive {:notification, :insert, %{"queue" => "pg_notifier_test"}}
        refute_receive {:notification, :insert, _}, 50
      end)

    assert_receive {:notification, :insert, %{"queue" => "pg_notifier_test"}}
  end

  test "an insert outside a transaction is announced once", ctx do
    {:ok, _} = Oban.insert(ctx.oban, job())

    assert_receive {:notification, :insert, %{"queue" => "pg_notifier_test"}}
    refute_receive {:notification, :insert, _}, 100
  end

  test "a rolled-back insert is not re-announced", ctx do
    {:error, :rollback} =
      Engram.Repo.with_tenant(ctx.user.id, fn ->
        {:ok, _} = Oban.insert(ctx.oban, job())
        assert_receive {:notification, :insert, _}
        Engram.Repo.rollback(:rollback)
      end)

    refute_receive {:notification, :insert, _}, 100
  end

  # The cluster arm lives inside the `config_env() == :prod` block, which
  # needs a full prod env to evaluate, so this pins the literal (the same
  # approach as ObanWebRolePluginsTest).
  test "config/runtime.exs uses the PG notifier only when DNS_CLUSTER_QUERY is set" do
    source = File.read!(@runtime)

    assert source =~
             ~r/if System.get_env\("DNS_CLUSTER_QUERY"\) do\n(?:(?!\s*end\n)[^\n]*\n)*?\s+config :engram, Oban, notifier: Oban.Notifiers.PG\n\s+end/,
           "config/runtime.exs must set `config :engram, Oban, notifier: Oban.Notifiers.PG`\n" <>
             "inside the DNS_CLUSTER_QUERY branch, and only there: unclustered nodes\n" <>
             "(self-host, single node) need the Postgres notifier to reach each other."

    assert length(Regex.scan(~r/notifier: Oban.Notifiers.PG/, source)) == 1
  end
end
