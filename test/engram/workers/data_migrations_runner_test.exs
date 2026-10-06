defmodule Engram.Workers.DataMigrationsRunnerTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.DataMigrations
  alias Engram.Workers.DataMigrationsRunner

  defmodule Finished do
    @behaviour Engram.DataMigration
    def name, do: "test_finished"
    def version, do: 1
    def run_pass, do: :done
  end

  defmodule Unfinished do
    @behaviour Engram.DataMigration
    def name, do: "test_unfinished"
    def version, do: 1
    def run_pass, do: :more
  end

  defmodule Exploding do
    @behaviour Engram.DataMigration
    def name, do: "test_exploding"
    def version, do: 1
    def run_pass, do: raise("boom")
  end

  defmodule Exiting do
    @behaviour Engram.DataMigration
    def name, do: "test_exiting"
    def version, do: 1
    def run_pass, do: exit(:timeout)
  end

  defmodule Counting do
    @behaviour Engram.DataMigration
    def name, do: "test_counting"
    def version, do: 1

    def run_pass do
      send(self(), :ran)
      :done
    end
  end

  setup do
    DataMigrations.reset_cache()
    :ok
  end

  test "a pass that finds no work marks it done" do
    assert DataMigrationsRunner.run(Finished) == :done
    assert DataMigrations.done?("test_finished", 1)
  end

  test "a pass with work left keeps it open" do
    assert DataMigrationsRunner.run(Unfinished) == :more
    refute DataMigrations.done?("test_unfinished", 1)
  end

  test "a done migration is skipped without running a pass" do
    :ok = DataMigrations.mark_done("test_counting", 1)
    assert DataMigrationsRunner.run(Counting) == :skipped
    refute_received :ran
  end

  test "a raising migration is contained and stays open" do
    assert DataMigrationsRunner.run(Exploding) == :error
    refute DataMigrations.done?("test_exploding", 1)
  end

  # A GenServer.call / Repo checkout timeout exits rather than raises; it
  # must not abort the migrations after it in the pass.
  test "an exiting migration is contained and stays open" do
    assert DataMigrationsRunner.run(Exiting) == :error
    refute DataMigrations.done?("test_exiting", 1)
  end

  describe "stuck migrations" do
    import ExUnit.CaptureLog
    import Ecto.Query

    alias Engram.DataMigrations.Entry

    defp age(name, opened_at, alerted_at \\ nil) do
      Repo.update_all(from(e in Entry, where: e.name == ^name),
        set: [opened_at: opened_at, alerted_at: alerted_at]
      )
    end

    defp days_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 86_400)

    test "an open migration younger than 7 days logs nothing" do
      log = capture_log([level: :error], fn -> DataMigrationsRunner.run(Unfinished) end)
      refute log =~ "data migration stuck"
    end

    test "an older one logs once and not again within 24h" do
      DataMigrationsRunner.run(Unfinished)
      age("test_unfinished", days_ago(8))

      log = capture_log([level: :error], fn -> DataMigrationsRunner.run(Unfinished) end)
      assert log =~ "data migration stuck"
      assert log =~ "test_unfinished"

      again = capture_log([level: :error], fn -> DataMigrationsRunner.run(Unfinished) end)
      refute again =~ "data migration stuck"
    end

    test "alerts again once the last alert is over 24h old" do
      DataMigrationsRunner.run(Unfinished)
      age("test_unfinished", days_ago(8), days_ago(2))

      log = capture_log([level: :error], fn -> DataMigrationsRunner.run(Unfinished) end)
      assert log =~ "data migration stuck"
    end

    test "an :error pass also counts as open" do
      DataMigrationsRunner.run(Exploding)
      age("test_exploding", days_ago(8))

      log = capture_log([level: :error], fn -> DataMigrationsRunner.run(Exploding) end)
      assert log =~ "data migration stuck"
    end

    test "a finished migration never alerts" do
      DataMigrationsRunner.run(Unfinished)
      age("test_unfinished", days_ago(8))
      :ok = DataMigrations.mark_done("test_unfinished", 1)

      log = capture_log([level: :error], fn -> DataMigrationsRunner.run(Unfinished) end)
      refute log =~ "data migration stuck"
    end
  end

  # The boot run (@reboot) and the hourly run must not overlap.
  test "a second enqueue within the unique period is deduplicated" do
    {:ok, first} = Oban.insert(DataMigrationsRunner.new(%{}))
    {:ok, second} = Oban.insert(DataMigrationsRunner.new(%{}))
    assert second.conflict?
    assert second.id == first.id
  end

  test "perform runs every registered migration" do
    assert :ok = perform_job(DataMigrationsRunner, %{})
  end

  test "every registered module implements the behaviour" do
    for mod <- DataMigrationsRunner.migrations() do
      Code.ensure_loaded!(mod)

      for {fun, 0} <- [name: 0, version: 0, run_pass: 0] do
        assert function_exported?(mod, fun, 0), "#{inspect(mod)} lacks #{fun}/0"
      end
    end
  end
end
