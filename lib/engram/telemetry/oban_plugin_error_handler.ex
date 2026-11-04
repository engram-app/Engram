defmodule Engram.Telemetry.ObanPluginErrorHandler do
  @moduledoc """
  Logs a failed Oban plugin run (Reindexer, Pruner, Lifeline, Cron) at
  :error. Oban reports a plugin's failure only as `[:oban, :plugin, :stop]`
  metadata `error:` (or `[:oban, :plugin, :exception]`), and nothing else
  listened, so a failed run was silent.

  The one that matters most: a daily `Oban.Reindexer` run cut short leaves
  an invalid `oban_jobs*_ccnew` index that every write still maintains and
  only the table owner can drop (`docs/context/oban-jobs-reindex.md`).

  The raw error is never logged (a `Postgrex.Error` can carry query text and
  parameters): only `Engram.Telemetry.error_kind/1` of it.
  """

  require Logger

  @handler_id :engram_oban_plugin_error
  @events [[:oban, :plugin, :stop], [:oban, :plugin, :exception]]

  @doc "Attach (or re-attach) the handler. Idempotent."
  @spec attach() :: :ok
  def attach do
    _ = :telemetry.detach(@handler_id)
    :ok = :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event([:oban, :plugin, kind], _measurements, %{plugin: plugin} = meta, _config)
      when kind == :exception or is_map_key(meta, :error) do
    error_kind =
      meta
      |> Map.get(:error, Map.get(meta, :reason))
      |> first_error()
      |> Engram.Telemetry.error_kind()

    Logger.error(
      "oban_plugin_failed plugin=#{inspect(plugin)} error_kind=#{error_kind}",
      Engram.Logger.Metadata.with_category(:error, :oban, error_kind: error_kind)
    )
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  # The Reindexer reports a list of `{query, error}`; the rest a bare error.
  defp first_error([{_query, error} | _]), do: error
  defp first_error(error), do: error
end
