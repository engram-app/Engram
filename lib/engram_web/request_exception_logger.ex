defmodule EngramWeb.RequestExceptionLogger do
  @moduledoc """
  Logs a request that crashed, in place of Bandit's own line: a server error
  (`Engram.Sentry.EventFilter.server_error?/1`) at error, which Sentry's
  LoggerHandler reports; a client-side failure (a body that stalled past
  `read_timeout`, a client that hung up) at warning, so it stays countable in
  Loki without paging. Any other 4xx exception (a 404 route) is already the
  request log's status line, and is not logged twice.

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
  alias Engram.Sentry.EventFilter

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

    cond do
      EventFilter.server_error?(exception) ->
        Logger.error(
          SafeException.safe_format(kind, exception, stacktrace),
          Metadata.with_category(:error, :http,
            domain: [:bandit],
            crash_reason: SafeException.to_safe_exception(kind, exception, stacktrace)
          )
        )

      client_failure?(exception) ->
        Logger.warning(
          "request failed client-side: #{Metadata.safe_reason(exception)}",
          Metadata.with_category(:warning, :http,
            domain: [:bandit],
            method: request_method(meta),
            status: client_status(exception)
          )
        )

      true ->
        :ok
    end

    :ok
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  defp client_failure?(%Bandit.HTTPError{}), do: true
  defp client_failure?(%Bandit.TransportError{}), do: true
  defp client_failure?(_exception), do: false

  # Bandit has no conn when it failed before building one.
  defp request_method(%{conn: %Plug.Conn{method: method}}), do: method
  defp request_method(_meta), do: nil

  # A TransportError has no status: the client is gone.
  defp client_status(%Bandit.TransportError{}), do: nil

  defp client_status(exception),
    do: exception |> Plug.Exception.status() |> Plug.Conn.Status.code()
end
