defmodule Engram.Logger.Category do
  @moduledoc """
  Single source of truth for log `category` atoms and the Loki sink-routing
  decision. See docs/superpowers/specs/2026-06-23-logging-taxonomy-redesign-design.md.

  Routing rule (sink model A): CloudWatch gets everything (Fluent Bit `Match *`);
  Loki keeps a line iff `loki_ship?/2` is true — all warnings/errors, plus
  `info` for the high-value categories below. `debug` never ships to Loki.
  """

  @categories [:http, :sync, :search, :auth, :billing, :crypto, :lifecycle, :oban, :boot]

  # info lines from these categories are state changes worth keeping in Loki.
  @info_to_loki [:billing, :crypto, :lifecycle, :oban, :boot]

  @spec all() :: [atom()]
  def all, do: @categories

  @spec valid?(atom()) :: boolean()
  def valid?(category), do: category in @categories

  @spec loki_ship?(Logger.level(), atom()) :: boolean()
  def loki_ship?(level, _category)
      when level in [:warning, :error, :critical, :alert, :emergency],
      do: true

  def loki_ship?(:info, category), do: category in @info_to_loki
  def loki_ship?(_level, _category), do: false
end
