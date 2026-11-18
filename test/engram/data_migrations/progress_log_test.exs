defmodule Engram.DataMigrations.ProgressLogTest do
  @moduledoc """
  A data migration's `:info` progress lines (rows repaired, blocked, waiting
  for the fleet) reach Loki: `:data` is not an `:info`-to-Loki category, so
  each line must carry the ship override (`Engram.DataMigration.progress_metadata/1`,
  `loki_ship: true` and `ship: "loki"`, what Fluent Bit routes on).
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.Backfill.IdWindows
  alias Engram.DataMigrations.EffectiveDates
  alias Engram.Notes
  alias Engram.Test.LogCapture

  require Logger

  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    IdWindows.reset_walks()
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp message(%{msg: {:string, s}}), do: s
  defp message(%{msg: {:report, r}}), do: inspect(r)
  defp message(%{msg: {f, a}}), do: :io_lib.format(f, a)

  defp note!(ctx, path) do
    {:ok, n} =
      Notes.upsert_note(
        ctx.user,
        ctx.vault,
        %{"path" => path, "content" => "x\n", "mtime" => 7.0},
        actor: "api"
      )

    n
  end

  test "progress_metadata/1 is category :data with the ship override" do
    meta = Engram.DataMigration.progress_metadata(total_count: 3)
    assert meta[:category] == :data
    assert meta[:loki_ship] == true
    assert meta[:ship] == "loki"
    assert meta[:total_count] == 3
  end

  describe "the runner's per-pass summary line" do
    alias Engram.Workers.DataMigrationsRunner

    defp summary(events) do
      assert [e] =
               Enum.filter(
                 events,
                 &(IO.chardata_to_string(message(&1)) == "data migration pass")
               )

      assert e.meta[:loki_ship] == true
      assert e.meta[:ship] == "loki"
      e.meta
    end

    test "one line with the walk counts", ctx do
      for p <- ["a.md", "b.md"] do
        n = note!(ctx, p)

        Repo.with_tenant!(ctx.user.id, fn ->
          Repo.update_all(from(x in Notes.Note, where: x.id == ^n.id), set: [eff_v: nil])
        end)
      end

      {:more, events} =
        LogCapture.with_events(fn -> DataMigrationsRunner.run(EffectiveDates) end)

      meta = summary(events)
      assert meta[:migration] == "note_effective_dates"
      assert meta[:version] == 1
      assert meta[:result] == :more
      assert meta[:fixed] == 2
      assert meta[:left] == false
      assert meta[:hit_budget] == false
      assert meta[:walks] =~ "note_effective_dates fixed=2 left=false"
    end

    test "a guard makes the result :blocked" do
      defmodule Guarded do
        @behaviour Engram.DataMigration
        def name, do: "test_guarded"
        def version, do: 1

        def run_pass do
          :ok = Engram.DataMigration.report(blocked: :test_guard)
          :more
        end
      end

      {:more, events} = LogCapture.with_events(fn -> DataMigrationsRunner.run(Guarded) end)

      meta = summary(events)
      assert meta[:result] == :blocked
      assert meta[:blocked] == "test_guard"
    end

    test "a migration that is already done logs nothing" do
      :ok = Engram.DataMigrations.mark_done(EffectiveDates.name(), EffectiveDates.version())

      {:skipped, events} =
        LogCapture.with_events(fn -> DataMigrationsRunner.run(EffectiveDates) end)

      refute Enum.any?(events, &(IO.chardata_to_string(message(&1)) == "data migration pass"))
    end

    test "a blocked: 0 count (FolderTable) is not :blocked" do
      defmodule ZeroBlocked do
        @behaviour Engram.DataMigration
        def name, do: "test_zero_blocked"
        def version, do: 1
        def run_pass, do: {:more, rows: 0, blocked: 0}
      end

      {:more, events} = LogCapture.with_events(fn -> DataMigrationsRunner.run(ZeroBlocked) end)
      refute Enum.any?(events, &(IO.chardata_to_string(message(&1)) == "data migration pass"))
    end
  end
end
