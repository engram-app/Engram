defmodule Engram.Workers.DataMigrationsRunnerTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

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

  defmodule Toggled do
    @behaviour Engram.DataMigration
    def name, do: "test_toggled"
    def version, do: 1
    def enabled?, do: Process.get(:toggled_enabled, true)
    def run_pass, do: :more
  end

  defmodule ReverifiedClean do
    @behaviour Engram.DataMigration
    def name, do: "test_reverified_clean"
    def version, do: 1
    def reverify?, do: true
    def run_pass, do: :done
  end

  defmodule ReverifiedDirty do
    @behaviour Engram.DataMigration
    def name, do: "test_reverified_dirty"
    def version, do: 1
    def reverify?, do: true
    def run_pass, do: {:more, users: 3}
  end

  # version/0 fails on its first call in a process (a transient failure before
  # the pass, like a done?/2 DB read timing out) and works after that.
  defmodule FlakyBeforePass do
    @behaviour Engram.DataMigration
    def name, do: "test_flaky_before_pass"

    def version do
      if Process.put(:flaky_called, true), do: 1, else: raise("transient")
    end

    def run_pass do
      send(self(), :ran)
      :more
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

  test "a failure before the pass never reopens a done row" do
    :ok = DataMigrations.mark_done("test_flaky_before_pass", 1)
    DataMigrations.reset_cache()

    assert DataMigrationsRunner.run(FlakyBeforePass) == :error
    refute_received :ran
    assert DataMigrations.done?("test_flaky_before_pass", 1)
  end

  describe "re-verify :done" do
    alias Engram.DataMigrations.Entry

    # A node whose done? cache is stale (another node reopened the row) must
    # close it again when its re-verify finds nothing, not leave it NULL.
    test "marks the row done again" do
      :ok = DataMigrations.mark_done("test_reverified_clean", 1)
      :ok = DataMigrations.reopen("test_reverified_clean", 1)
      :persistent_term.put({DataMigrations, "test_reverified_clean", 1}, true)
      assert is_nil(Repo.get!(Entry, "test_reverified_clean").completed_at)

      assert DataMigrationsRunner.run(ReverifiedClean, true) == :done
      refute is_nil(Repo.get!(Entry, "test_reverified_clean").completed_at)
    end

    # The re-verify-hour run was deduped or failed: the next hourly run catches up.
    test "outside the re-verify hour, a verification older than 25 h re-verifies" do
      :ok = DataMigrations.mark_done("test_reverified_clean", 1)
      stale = DateTime.add(DateTime.utc_now(), -26 * 3600)

      Repo.update_all(from(e in Entry, where: e.name == "test_reverified_clean"),
        set: [completed_at: stale]
      )

      assert DataMigrationsRunner.run(ReverifiedClean, false) == :done
      fresh = Repo.get!(Entry, "test_reverified_clean").completed_at
      assert DateTime.compare(fresh, stale) == :gt

      # Just verified: the next off-hour run skips it.
      assert DataMigrationsRunner.run(ReverifiedClean, false) == :skipped
    end
  end

  describe "stuck migrations" do
    import ExUnit.CaptureLog

    alias Engram.DataMigrations.Entry

    defp age(name, opened_at, alerted_at \\ nil) do
      Repo.update_all(from(e in Entry, where: e.name == ^name),
        set: [opened_at: opened_at, alerted_at: alerted_at]
      )
    end

    defp days_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 86_400)

    test "disabled time does not count: re-enabling after > 7 days does not page" do
      Process.put(:toggled_enabled, true)
      DataMigrationsRunner.run(Toggled)
      age("test_toggled", days_ago(8))

      Process.put(:toggled_enabled, false)
      assert DataMigrationsRunner.run(Toggled) == :skipped
      entry = Repo.get!(Entry, "test_toggled")
      assert DateTime.diff(DateTime.utc_now(), entry.opened_at) < 60
      assert is_nil(entry.completed_at)

      Process.put(:toggled_enabled, true)
      log = capture_log([level: :error], fn -> DataMigrationsRunner.run(Toggled) end)
      refute log =~ "data migration stuck"
    end

    test "a disabled migration with no row gets none" do
      Process.put(:toggled_enabled, false)
      assert DataMigrationsRunner.run(Toggled) == :skipped
      assert is_nil(Repo.get(Entry, "test_toggled"))
    end

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

    # capture_log_messages is off, so the Logger.error alone never reaches
    # Sentry; the stuck alert captures a message explicitly.
    test "a stuck migration is reported to Sentry" do
      Sentry.Test.setup_sentry()
      DataMigrationsRunner.run(Unfinished)
      age("test_unfinished", days_ago(8))

      capture_log([level: :error], fn -> DataMigrationsRunner.run(Unfinished) end)

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert event.message.formatted =~ "data migration stuck"
      assert event.extra.migration == "test_unfinished"
      assert event.extra.version == 1
      assert is_binary(event.extra.opened_at)
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

  # The boot run (@reboot) must not be swallowed by an hourly run that
  # already COMPLETED: only an incomplete run blocks a new one.
  test "a completed run does not deduplicate the next enqueue" do
    {:ok, first} = Oban.insert(DataMigrationsRunner.new(%{}))

    Repo.update_all(from(j in Oban.Job, where: j.id == ^first.id),
      set: [state: "completed", completed_at: DateTime.utc_now()]
    )

    {:ok, second} = Oban.insert(DataMigrationsRunner.new(%{}))
    refute second.conflict?
    assert second.id != first.id
  end

  test "perform runs every registered migration" do
    # KeyAliases runs only while the v5 rebuild is on.
    Engram.ServiceConfig.put_override(:index_rebuild, "on")
    # `on` needs an open ledger (no budget reads as halted).
    Engram.Cache.clear_local(:rebuild)
    Repo.query!("DELETE FROM rebuild_ledger")
    Engram.Rebuild.set_budget(1_000_000)
    # NoteMeta ships off until staging validates it.
    Engram.ServiceConfig.put_override(:note_meta_backfill, true)
    # PersonOriginBackfill is disabled (no ledger row) without PostHog reads.
    posthog = [:posthog_key, :posthog_erasure_api_key, :posthog_project_id]
    prior = Map.new(posthog, &{&1, Application.fetch_env(:engram, &1)})

    on_exit(fn ->
      Enum.each(prior, fn
        {k, {:ok, v}} -> Application.put_env(:engram, k, v)
        {k, :error} -> Application.delete_env(:engram, k)
      end)
    end)

    Enum.each(posthog, &Application.put_env(:engram, &1, "test"))

    # #2494: an open row no registered migration owns (an index_versions key
    # a deploy left behind) keeps its clock held, so reviving it later does
    # not page "stuck" on its first pass of real work.
    _ = Engram.DataMigrations.note_open("test_unfinished", 1)
    eight_days_ago = DateTime.add(DateTime.utc_now(), -8 * 86_400)

    Repo.update_all(from(e in Engram.DataMigrations.Entry, where: e.name == "test_unfinished"),
      set: [opened_at: eight_days_ago]
    )

    assert :ok = perform_job(DataMigrationsRunner, %{})

    orphan = Repo.get!(Engram.DataMigrations.Entry, "test_unfinished")
    assert DateTime.diff(DateTime.utc_now(), orphan.opened_at) < 60

    revived =
      ExUnit.CaptureLog.capture_log([level: :error], fn ->
        DataMigrationsRunner.run(Unfinished)
      end)

    refute revived =~ "data migration stuck"

    # Every pass leaves a ledger row: mark_done/2 on :done, note_open/2 on :more.
    rows = Repo.all(from(e in Engram.DataMigrations.Entry, select: e.name))

    for mod <- DataMigrationsRunner.migrations() do
      assert mod.name() in rows, "#{inspect(mod)} did not run (no ledger row)"
    end
  end

  # The runner's list is hand-kept (order matters), so a new DataMigration
  # that is never registered would silently never run.
  test "every DataMigration in the app is registered with the runner" do
    missing =
      Engram.Test.ObanWorkers.implementing(Engram.DataMigration) --
        DataMigrationsRunner.migrations()

    assert missing == [], "register in DataMigrationsRunner @migrations: #{inspect(missing)}"
  end

  test "every registered module implements the behaviour" do
    for mod <- DataMigrationsRunner.migrations() do
      Code.ensure_loaded!(mod)

      assert Engram.DataMigration in (mod.module_info(:attributes)[:behaviour] || []),
             "#{inspect(mod)} lacks @behaviour Engram.DataMigration"
    end
  end

  # Owner rule (2026-11-06): every data migration ships with a kill switch,
  # `enabled?/0` backed by a ServiceConfig service override, so a bad pass
  # stops fleet-wide in seconds without a deploy. These predate the rule.
  @before_kill_switch_rule [
    Engram.DataMigrations.IndexVersions,
    Engram.DataMigrations.CrdtStateSeed,
    Engram.DataMigrations.EnvelopeFormat,
    Engram.DataMigrations.LinkResolutionKeys,
    Engram.DataMigrations.NotePayloadStamps,
    Engram.DataMigrations.NoteSplit,
    Engram.DataMigrations.NoteIndexState,
    Engram.DataMigrations.NoteSizes,
    Engram.DataMigrations.FolderTable,
    Engram.DataMigrations.KeyAliases,
    Engram.DataMigrations.PersonOriginBackfill,
    Engram.DataMigrations.EffectiveDates
  ]

  test "every data migration newer than the kill-switch rule has a working kill switch" do
    alias Engram.ServiceConfig.Overrides

    # The runtime-override path, as prod runs it (OverridesTest's setup).
    Engram.ServiceConfig.put_override(:service_overrides_enabled, true)
    Engram.Cache.clear_local(:service_overrides)
    Engram.Cache.clear_local(:service_overrides_last_good)
    on_exit(fn -> Engram.Cache.clear_local(:service_overrides) end)

    for mod <- DataMigrationsRunner.migrations() -- @before_kill_switch_rule do
      Code.ensure_loaded!(mod)
      assert function_exported?(mod, :enabled?, 0), "#{inspect(mod)}: add enabled?/0"

      source = File.read!(mod.module_info(:compile)[:source])

      assert [_, key] = Regex.run(~r/ServiceConfig\.get\(:(\w+)/, source),
             "#{inspect(mod)}: back enabled?/0 with ServiceConfig.get(:key, true)"

      key = String.to_existing_atom(key)
      # A key missing here silently falls back to env: no runtime switch.
      assert key in Overrides.keys(), "#{inspect(mod)}: add #{key} to ServiceConfig.Overrides"

      # Either default (a migration may ship off until staging validates it,
      # e.g. NoteMeta), but the override must switch it both ways, and
      # deleting the override must restore the default.
      default = mod.enabled?()
      assert :ok = Overrides.put(key, false, by: "test")
      refute mod.enabled?(), "#{inspect(mod)}: the override must switch it off"
      assert :ok = Overrides.put(key, true, by: "test")
      assert mod.enabled?(), "#{inspect(mod)}: the override must switch it on"
      assert :ok = Overrides.delete(key, by: "test")
      assert mod.enabled?() == default
    end
  end

  # Rows written while the gate was blocked in a deploy reopen the migration
  # most days; at :warning that routine line drowns a real regression.
  test "a routine re-verify reopen logs at :info with what it found" do
    import ExUnit.CaptureLog
    require Logger
    :ok = DataMigrations.mark_done("test_reverified_dirty", 1)

    warn =
      capture_log([level: :warning], fn ->
        assert DataMigrationsRunner.run(ReverifiedDirty, true) == :more
      end)

    refute warn =~ "reopened"
    refute DataMigrations.done?("test_reverified_dirty", 1)

    :ok = DataMigrations.mark_done("test_reverified_dirty", 1)
    DataMigrations.reset_cache()
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    info =
      capture_log([level: :info], fn ->
        assert DataMigrationsRunner.run(ReverifiedDirty, true) == :more
      end)

    assert info =~ "data migration reopened by re-verify"
    assert info =~ "users=3"
  end

  test "a pass returning {:more, detail} keeps it open" do
    assert DataMigrationsRunner.run(ReverifiedDirty) == :more
    refute DataMigrations.done?("test_reverified_dirty", 1)
  end
end
