defmodule Engram.Sentry.EventFilter do
  @moduledoc """
  Sentry `:before_send` callback: only server errors go to Sentry. Everything
  it keeps is then scrubbed by `Engram.Sentry.Scrubber`.

  `Sentry.PlugCapture` (endpoint.ex) reports every exception a request raises,
  whatever its status, while `EngramWeb.RequestExceptionLogger` deliberately
  logs only 5xx at error. On 2026-10-20 a stalled Obsidian upload hit the 15s
  body `read_timeout`: `Bandit.HTTPError` (400/408) before routing, then
  `Bandit.TransportError` rendering that 4xx to a socket the client had
  already closed. Both paged as server errors (ENGRAM-BACKEND-Q, -X).

  `server_error?/1` is the one policy, shared with RequestExceptionLogger,
  which logs the client-side failures at warning so they stay countable.
  """

  alias Engram.Sentry.Scrubber

  @spec before_send(Sentry.Event.t()) :: Sentry.Event.t() | nil
  def before_send(%Sentry.Event{} = event) do
    if client_failure?(event), do: nil, else: Scrubber.scrub(event)
  end

  @doc """
  Whether a request's exception is ours to fix: a 5xx status, and not a
  client that went away (`Bandit.TransportError`: "cannot be signalled back
  to the client", so there is no status to have).
  """
  @spec server_error?(Exception.t()) :: boolean()
  def server_error?(%Bandit.TransportError{}), do: false

  def server_error?(exception),
    do: exception |> Plug.Exception.status() |> Plug.Conn.Status.code() >= 500

  defp client_failure?(%Sentry.Event{original_exception: %Bandit.TransportError{}}), do: true

  # Status only means something for a request. phoenix_ecto maps
  # Ecto.NoResultsError to 404 for every caller, and one raised by a worker
  # is a bug.
  defp client_failure?(%Sentry.Event{source: :plug, original_exception: e})
       when is_exception(e),
       do: not server_error?(e)

  defp client_failure?(_event), do: false
end
