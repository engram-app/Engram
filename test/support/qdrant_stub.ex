defmodule Engram.QdrantStub do
  @moduledoc """
  Bypass response bodies for Qdrant's `/points/query/batch`, which hybrid
  search sends (one request per leg) and fuses client-side.
  """

  @doc """
  A batch answer from a single-query body (`%{"result" => points}` or
  `%{"result" => %{"points" => points}}`): the points are the dense leg, in
  the given order, and the keyword leg is empty. Fused scores are then
  `1 / (2 + rank)`.
  """
  def batch(%{"result" => result}, keyword \\ []) do
    points = if is_list(result), do: result, else: Map.get(result, "points", [])
    %{"result" => [%{"points" => points}, %{"points" => keyword}]}
  end

  @doc "The fused score of a point at zero-based `rank` in one leg."
  def rrf(rank), do: 1 / (2 + rank)
end
