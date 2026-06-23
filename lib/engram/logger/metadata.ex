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
  end
end
