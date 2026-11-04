defmodule Engram.Telemetry.ObanPluginErrorHandlerTest do
  # A failed Oban plugin run (Reindexer, Pruner, Lifeline) was silent: Oban
  # reports it only as telemetry and nothing listened. A cut-short reindex
  # leaves an invalid `*_ccnew` index that only the owner can drop
  # (docs/context/oban-jobs-reindex.md), so it must be loud.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Engram.Telemetry.ObanPluginErrorHandler

  setup do
    ObanPluginErrorHandler.attach()
    :ok
  end

  test "a plugin run that ended in error logs at :error with the plugin" do
    log =
      capture_log(fn ->
        :telemetry.execute([:oban, :plugin, :stop], %{duration: 1}, %{
          plugin: Oban.Reindexer,
          error: [{"REINDEX INDEX CONCURRENTLY x", %RuntimeError{message: "lock timeout"}}]
        })
      end)

    assert log =~ "oban_plugin_failed plugin=Oban.Reindexer"
    refute log =~ "lock timeout"
  end

  test "a clean plugin run logs nothing" do
    log =
      capture_log(fn ->
        :telemetry.execute([:oban, :plugin, :stop], %{duration: 1}, %{plugin: Oban.Reindexer})
      end)

    refute log =~ "oban_plugin_failed"
  end
end
