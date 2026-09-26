defmodule EngramWeb.RequestExceptionLogger do
  @moduledoc """
  Logs a request that crashed with a 5xx, in place of Bandit's own line.

  Bandit logs `Exception.format/3` of the raw exception, so a controller that
  crashes matching on params prints the params (note paths, content) to Loki.
  Its log is switched off (`log_exceptions_with_status_codes: []`, config.exs)
  and this handler logs the same event through
  `Engram.Logger.SafeException`: type, allowlisted message, and a stacktrace
  with file/line but no argument values. Same `crash_reason` metadata shape
  Bandit sets, sanitized, so Sentry's LoggerHandler behaves as before.
  """

  alias Engram.Logger.Metadata
  alias Engram.Logger.SafeException

  require Logger

  @handler_id :engram_request_exception_logger
  @event [:bandit, :request, :exception]

  @doc "Attach (or re-attach) the handler. Idempotent."
  def attach do
    _ = :telemetry.detach(@handler_id)
    :ok = :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event(@event, _measurements, %{exception: exception} = meta, _config) do
    kind = Map.get(meta, :kind, :error)
    stacktrace = Map.get(meta, :stacktrace, [])

    if server_error?(exception) do
      Logger.error(
        SafeException.safe_format(kind, exception, stacktrace),
        Metadata.with_category(:error, :http,
          domain: [:bandit],
          crash_reason: SafeException.to_safe_exception(kind, exception, stacktrace)
        )
      )
    end

    :ok
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  # Bandit's default was 500..599; mirror it.
  defp server_error?(exception) do
    exception |> Plug.Exception.status() |> Plug.Conn.Status.code() >= 500
  end
end
