defmodule Engram.Logger.Metadata do
  @moduledoc """
  Builds Logger metadata with a validated `category` and the computed
  `loki_ship` routing flag. Use at log call sites:

      Logger.info("subscription created",
        Engram.Logger.Metadata.with_category(:info, :billing,
          paddle_subscription_id: id))
  """
  alias Engram.Logger.Category

  @spec with_category(Logger.level(), atom(), keyword()) :: keyword()
  @doc """
  A log-safe rendering of a rescued exception.

  `Exception.message/1` is not "our own text". `CaseClauseError`, `MatchError`,
  `KeyError`, `Protocol.UndefinedError` and `Jason.EncodeError` all render
  `inspect(term)` of the value that blew up — and in this codebase the terms
  flowing through a rescue are frequently note content, a path, or a search
  query.

  Moving such a message into metadata does NOT make it safe:
  `Engram.Logger.RedactFilter` scrubs by KEY, and neither `:error`, `:reason`
  nor `:message` is in its set, so Loki and CloudWatch print it verbatim. (The
  Sentry metadata allowlist in `Engram.Application` is separate and narrower.)

  So the filter is on the exception TYPE. Allowlisted types keep their message
  because it is our own text or the database's; everything else contributes its
  class only.

  An allowlist, not a denylist: a new exception type in Elixir or a dependency
  defaults to safe-and-useless rather than to leaking.
  """
  @safe_message_exceptions [
    Postgrex.Error,
    DBConnection.ConnectionError,
    Ecto.ConstraintError,
    Ecto.StaleEntryError,
    Ecto.QueryError
  ]

  @spec safe_reason(Exception.t() | struct()) :: String.t()
  def safe_reason(%mod{} = e) when mod in @safe_message_exceptions, do: Exception.message(e)
  def safe_reason(%mod{}), do: inspect(mod)

  def with_category(level, category, metadata \\ []) do
    unless Category.valid?(category) do
      raise ArgumentError, "unknown log category: #{inspect(category)}"
    end

    metadata
    |> Keyword.put(:category, category)
    |> Keyword.put(:loki_ship, Category.loki_ship?(level, category))
    |> put_trace_context()
  end

  defp put_trace_context(metadata) do
    case Engram.Observability.Otel.span_context() do
      {trace_id, span_id} ->
        metadata
        |> Keyword.put(:trace_id, trace_id)
        |> Keyword.put(:span_id, span_id)

      nil ->
        metadata
    end
  end
end
