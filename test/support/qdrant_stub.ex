defmodule Engram.QdrantStub do
  @moduledoc """
  Bypass response bodies for hybrid search. Hybrid sends the dense and
  keyword legs as one `/points/query/batch` (ids and scores), fuses them
  client-side, then retrieves the fused points (`POST /points`) for their
  payload and vectors.

  `batch/3` builds the batch answer and records its points under the Bypass
  port; `stub_retrieve/2` answers the retrieve from that record, so a test
  states its points once.
  """

  @table __MODULE__

  @doc "Creates the point record (test_helper)."
  def init, do: :ets.new(@table, [:named_table, :public, :set])

  @doc """
  A batch answer from a single-query body (`%{"result" => points}` or
  `%{"result" => %{"points" => points}}`): the points are the dense leg, in
  the given order, and `keyword` is the keyword leg. Points in both legs are
  fused once. Every point is recorded for `stub_retrieve/2`.
  """
  def batch(%Plug.Conn{port: port}, %{"result" => result}, keyword \\ []) do
    points = if is_list(result), do: result, else: Map.get(result, "points", [])
    for p <- points ++ keyword, do: :ets.insert(@table, {{port, p["id"]}, p})
    %{"result" => [%{"points" => points}, %{"points" => keyword}]}
  end

  @doc "Answers `POST /collections/{col}/points` (retrieve) from what `batch/3` recorded."
  def stub_retrieve(bypass, col \\ "engram_notes") do
    :ets.delete(@table, {bypass.port, :last_retrieve})

    Bypass.stub(bypass, "POST", "/collections/#{col}/points", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      %{"ids" => ids} = body = Jason.decode!(raw)
      :ets.insert(@table, {{conn.port, :last_retrieve}, body})

      points =
        for id <- ids, [{_, p}] <- [:ets.lookup(@table, {conn.port, id})] do
          Map.delete(p, "score")
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => points}))
    end)
  end

  @doc "The body of the last retrieve `stub_retrieve/2` answered on `bypass`, or nil."
  def last_retrieve(%Bypass{port: port}) do
    case :ets.lookup(@table, {port, :last_retrieve}) do
      [{_, body}] -> body
      [] -> nil
    end
  end

  @doc "The fused score of a point at zero-based `rank` in one leg."
  def rrf(rank), do: 1 / (2 + rank)
end
