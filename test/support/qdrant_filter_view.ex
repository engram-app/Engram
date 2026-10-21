defmodule Engram.QdrantFilterView do
  @moduledoc """
  Shape-test helper for the dual-format filters (Task 15.4). While
  `:legacy_filter_fields` is on, every condition is `%{should: [legacy, v5]}`;
  `legacy_view/1` replaces each such group with its legacy member, so a test
  that pins the legacy shape keeps pinning it. The v5 member is covered by
  `qdrant_filter_test.exs` and the Qdrant round trip.
  """

  def legacy_view(conditions) when is_list(conditions), do: Enum.map(conditions, &legacy_view/1)
  def legacy_view(%{should: [legacy, _v5]}), do: legacy
  def legacy_view(%{"should" => [legacy, _v5]}), do: legacy
  def legacy_view(%{must: must} = filter), do: %{filter | must: legacy_view(must)}
  def legacy_view(%{"must" => must} = filter), do: %{filter | "must" => legacy_view(must)}
  def legacy_view(other), do: other
end
