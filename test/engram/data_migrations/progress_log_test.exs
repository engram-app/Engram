defmodule Engram.DataMigrations.ProgressLogTest do
  @moduledoc """
  A data migration's `:info` progress lines (rows repaired, blocked, waiting
  for the fleet) reach Loki: `:data` is not an `:info`-to-Loki category, so
  each line must carry the ship override (`Engram.DataMigration.progress_metadata/1`,
  `loki_ship: true` and `ship: "loki"`, what Fluent Bit routes on).
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  require Logger

  alias Engram.Backfill.IdWindows
  alias Engram.DataMigrations.{FileTimes, NoteBodyColumnsNull}
  alias Engram.Notes
  alias Engram.Test.LogCapture

  defp old_fleet,
    do: [
      peers: fn -> [:"engram@10.0.0.9"] end,
      sync: fn -> :ok end,
      multicall: fn _ -> [{:error, {:exception, :undef, []}}] end
    ]

  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    FileTimes.forget()
    IdWindows.reset_walks()
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp shipped?(events, text) do
    case Enum.filter(events, &(IO.chardata_to_string(message(&1)) =~ text)) do
      [] -> flunk("no #{inspect(text)} line in #{length(events)} events")
      found -> Enum.all?(found, &(&1.meta[:loki_ship] == true and &1.meta[:ship] == "loki"))
    end
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

  test "NoteBodyColumnsNull: the blocked and nulled lines ship", ctx do
    n = note!(ctx, "a.md")
    Engram.Fixtures.old_release_notes_copy!(n.id)

    {_, events} =
      LogCapture.with_events(fn -> NoteBodyColumnsNull.run_pass(fleet: old_fleet()) end)

    assert shipped?(events, "note body columns null blocked")

    {_, events} = LogCapture.with_events(fn -> NoteBodyColumnsNull.run_pass() end)
    assert shipped?(events, "note body columns nulled")
  end

  test "FileTimes: the waiting and repaired lines ship", ctx do
    n = note!(ctx, "t.md")

    Repo.with_tenant!(ctx.user.id, fn ->
      Repo.update_all(from(x in Notes.Note, where: x.id == ^n.id), set: [mtime_at: nil])
    end)

    {_, events} = LogCapture.with_events(fn -> FileTimes.run_pass(fleet: old_fleet()) end)
    assert shipped?(events, "file times waiting for the fleet")

    {_, events} = LogCapture.with_events(fn -> FileTimes.run_pass() end)
    assert shipped?(events, "file times repaired")
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
      for p <- ["a.md", "b.md"], do: Engram.Fixtures.old_release_notes_copy!(note!(ctx, p).id)

      {:more, events} =
        LogCapture.with_events(fn -> DataMigrationsRunner.run(NoteBodyColumnsNull) end)

      meta = summary(events)
      assert meta[:migration] == "note_body_columns_null"
      assert meta[:version] == 1
      assert meta[:result] == :more
      assert meta[:fixed] == 2
      assert meta[:left] == false
      assert meta[:hit_budget] == false
      assert meta[:walks] =~ "note_body_columns_null fixed=2 left=false"
    end

    test "a guard makes the result :blocked", ctx do
      Engram.Fixtures.old_release_notes_copy!(note!(ctx, "a.md").id)
      Repo.query!("DROP TRIGGER notes_crdt_head_invalidate ON notes")

      {:more, events} =
        LogCapture.with_events(fn -> DataMigrationsRunner.run(NoteBodyColumnsNull) end)

      meta = summary(events)
      assert meta[:result] == :blocked
      assert meta[:blocked] == "head_trigger_not_on_nonce"
      assert meta[:fixed] == 0
    end

    test "FileTimes reports its open and clean tables", ctx do
      note!(ctx, "t.md")
      {_, events} = LogCapture.with_events(fn -> DataMigrationsRunner.run(FileTimes) end)
      meta = summary(events)
      assert meta[:migration] == "file_times"
      assert is_binary(meta[:open]) and is_binary(meta[:clean])
      assert meta[:walks] =~ "file_times:notes"
    end

    test "a migration that is already done logs :skipped" do
      :ok =
        Engram.DataMigrations.mark_done(NoteBodyColumnsNull.name(), NoteBodyColumnsNull.version())

      {:skipped, events} =
        LogCapture.with_events(fn -> DataMigrationsRunner.run(NoteBodyColumnsNull) end)

      assert summary(events)[:result] == :skipped
    end
  end
end
