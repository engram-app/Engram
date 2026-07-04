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
