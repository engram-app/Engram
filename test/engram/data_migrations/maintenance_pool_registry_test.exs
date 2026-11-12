defmodule Engram.DataMigrations.MaintenancePoolRegistryTest do
  @moduledoc """
  Every registered DataMigration (`DataMigrationsRunner.migrations/0`, so a
  new one is covered without editing this file) runs its pass, and its
  `left/0` where it has one, with `Engram.Repo.Maintenance` CONFIGURED and
  connected as `engram_maintenance`: the fleet path prod takes
  (docs/context/rls-enforcement-testing-traps.md, trap 9). The rest of the
  suite runs the per-user pool, where fleet-only code never executes;
  `NameTerms.left/0`'s `subquery(... select: 1)` raised Ecto.SubQueryError on
  every prod hop and no unit test saw it (R3 rehearsal, 2026-11-11).

  Fixtures are committed (the pool is a second connection) and removed on
  exit. Each pass is called directly (the runner skips one its ledger marks
  done), every exception is reported, and the maintenance-pool queries it
  ran are counted and printed (`fleet-coverage` lines), so a migration whose
  pass reaches no fleet query says so instead of passing silently.

  The guard must be able to fail: a dummy migration with the NameTerms bug
  goes through the same check and is reported.
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Backfill.TenantScan
  alias Engram.Crypto
  alias Engram.DataMigrations.FolderTable
  alias Engram.Repo
  alias Engram.Repo.Maintenance
  alias Engram.Workers.{BackfillCrdtState, DataMigrationsRunner, ReconcileNotePayloads}

  # Both pools share the repo telemetry prefix (the test pool takes
  # `Repo.config/0`); the event's `repo` names the pool.
  @query_event [:engram, :repo, :query]

  @entry_points [
    {ReconcileNotePayloads, :queue_window, 2},
    {FolderTable, :scope, 2},
    {BackfillCrdtState, :enqueue_missing, 0}
  ]

  defmodule BrokenOnFleet do
    @moduledoc false
    import Ecto.Query

    alias Engram.Backfill.TenantScan
    alias Engram.Notes.Note

    # The NameTerms bug, on purpose: fine on the per-user pool, raises on
    # the fleet one.
    def name, do: "broken_on_fleet"
    def version, do: 1
    def run_pass, do: :done

    def left do
      case TenantScan.pool() do
        {:fleet, repo} -> repo.aggregate(subquery(from(n in Note, select: 1)), :count)
        :per_user -> :unknown
      end
    end
  end

  # The committed fixtures live for the module, and are removed after every
  # test's sandbox is gone: a pass that writes through the app pool (in the
  # test's sandbox transaction) holds row locks on them until then, so a
  # per-test cleanup deleting them would wait on its own test and time out.
  setup_all do
    jobs_before =
      Sandbox.unboxed_run(Repo, fn -> Repo.one(from(j in Oban.Job, select: max(j.id))) || 0 end)

    # Two tenants, a note each, root level (no folder RI action on exit).
    made =
      Sandbox.unboxed_run(Repo, fn ->
        for i <- 1..2 do
          {:ok, user} = Crypto.ensure_user_dek(insert(:user))
          insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
          {:ok, vault, _} = Engram.Vaults.register_vault(user, "Reg#{i}", Ecto.UUID.generate())

          {:ok, _} =
            Engram.Notes.upsert_note(user, vault, %{"path" => "r#{i}.md", "content" => "x"},
              actor: "api"
            )

          user
        end
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        for user <- made do
          Repo.delete_all(from(v in Engram.Vaults.Vault, where: v.user_id == ^user.id),
            skip_tenant_check: true
          )

          Repo.delete!(user, skip_tenant_check: true)
        end

        Repo.delete_all(from(j in Oban.Job, where: j.id > ^jobs_before))
      end)
    end)

    :ok
  end

  setup do
    # `stacktrace: true`: each fleet query's telemetry names its callers, so
    # the named entry points below can be checked without a tracer.
    Engram.Test.MaintenancePool.start!(stacktrace: true)

    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      @query_event,
      fn _, _, %{repo: repo} = meta, _ ->
        if repo == Maintenance do
          send(test_pid, :fleet_query)

          for {m, f, a, _} <- meta[:stacktrace] || [],
              {m, f, a} in @entry_points,
              do: send(test_pid, {:entry_point, {m, f, a}})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  # A healthy, empty Qdrant for every route, so passes gated on it (the
  # Qdrant gate, a scroll, the `n` index) reach their Postgres fleet walk.
  defp stub_qdrant! do
    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    Engram.Cache.clear_local(:rebuild)
    Engram.Cache.clear_local(:qdrant_pressure)

    col = "/collections/" <> Engram.Vector.Qdrant.collection_name()

    # Every route (`expect/2` matches any): the collection is green with the
    # `n` index, reads find nothing, anything else is a 404 (an unsupported
    # or unreadable endpoint, which the callers already handle).
    Bypass.expect(bypass, fn conn ->
      cond do
        conn.method == "GET" and conn.request_path == col ->
          json(conn, 200, %{
            "status" => "ok",
            "result" => %{
              "status" => "green",
              "optimizer_status" => "ok",
              "update_queue" => %{"length" => 0},
              "payload_schema" => %{"n" => %{"data_type" => "uuid"}}
            }
          })

        conn.method == "POST" and String.starts_with?(conn.request_path, col <> "/points") ->
          json(conn, 200, %{
            "status" => "ok",
            "result" => %{"points" => [], "next_page_offset" => nil, "count" => 0}
          })

        true ->
          json(conn, 404, %{"status" => %{"error" => "not found"}})
      end
    end)
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp fleet_queries(n \\ 0) do
    receive do
      :fleet_query -> fleet_queries(n + 1)
    after
      0 -> n
    end
  end

  # `{mod, :disabled | %{pass:, left:, fleet_queries:}}` per migration.
  defp exercise(mods) do
    Enum.map(mods, fn mod ->
      Code.ensure_loaded!(mod)
      _ = fleet_queries()

      if function_exported?(mod, :enabled?, 0) and not mod.enabled?() do
        {mod, :disabled}
      else
        pass = attempt(fn -> mod.run_pass() end)

        left =
          if function_exported?(mod, :left, 0), do: attempt(fn -> mod.left() end), else: :none

        {mod, %{pass: pass, left: left, fleet_queries: fleet_queries()}}
      end
    end)
  end

  defp attempt(fun) do
    {:ok, fun.()}
  rescue
    e -> {:raised, e |> Exception.message() |> String.slice(0, 400)}
  catch
    kind, reason -> {:raised, "#{kind}: " <> (reason |> inspect() |> String.slice(0, 400))}
  end

  defp failures(rows) do
    for {mod, %{} = o} <- rows,
        step <- [:pass, :left],
        match?({:raised, _}, o[step]),
        do: {mod, step, o[step]}
  end

  defp report(rows) do
    for {mod, outcome} <- rows do
      line =
        case outcome do
          :disabled -> "disabled (enabled?/0 false), not run"
          %{fleet_queries: 0} = o -> "NO fleet query; pass #{tag(o.pass)}, left #{tag(o.left)}"
          o -> "#{o.fleet_queries} fleet queries; pass #{tag(o.pass)}, left #{tag(o.left)}"
        end

      IO.puts("fleet-coverage #{inspect(mod)}: #{line}")
    end
  end

  defp tag(:none), do: "none"
  defp tag({tag, _}), do: tag

  @tag :capture_log
  test "every registered migration's pass and left/0 run on the maintenance pool" do
    assert {:fleet, _} = TenantScan.pool()
    stub_qdrant!()
    rows = exercise(DataMigrationsRunner.migrations())
    report(rows)
    assert failures(rows) == []

    # ponytail: three named fleet entry points (the ones the counts alone do
    # not name), each seen issuing a query on the maintenance pool; extend
    # @entry_points when another needs naming.
    assert entry_points_hit() == MapSet.new(@entry_points)
  end

  # The named entry points a fleet query was issued from.
  defp entry_points_hit(acc \\ MapSet.new()) do
    receive do
      {:entry_point, mfa} -> entry_points_hit(MapSet.put(acc, mfa))
    after
      0 -> acc
    end
  end

  test "the guard catches a fleet-only failure" do
    rows = exercise([BrokenOnFleet])
    report(rows)
    assert [{BrokenOnFleet, :left, {:raised, message}}] = failures(rows)
    assert message =~ "subquery"
  end
end
