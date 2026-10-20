defmodule Engram.Vector.QdrantStrictCallersTest do
  @moduledoc """
  Every Qdrant call the app makes fits the Qdrant Cloud strict-mode hard
  limits (`QdrantLayout.desired_strict(:cloud)`). Qdrant refuses an
  over-limit request with a 400, and only on Cloud, so neither CI nor staging
  (both self-host) would ever see it.

  Two halves: the limits sit above the caller maxima `Qdrant` declares, with
  headroom, and the call sites that take an unbounded input (a note's point
  ids, a tag list) are driven through Bypass with inputs far past those
  maxima, checking every request body the way Qdrant 1.19.2 does
  (`lib/collection/src/operations/verification/`): `limit` against
  `max_query_limit`, each `has_id`/`match.any` against `condition_max_size`,
  the condition count against `filter_max_conditions`, `searches` against
  `search_max_batchsize`, `timeout` against `max_timeout`.
  """
  use ExUnit.Case, async: false

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant
  alias Engram.Vector.QdrantLayout

  @strict QdrantLayout.desired_strict(:cloud)

  describe "limits vs the declared caller maxima" do
    test "scroll and query pages: 2x headroom over the largest page" do
      assert @strict["max_query_limit"] >= 2 * Qdrant.max_page()
      # The search pool: 100 notes x 4 (Search.clamp_limit/1, the 4x over-fetch).
      assert Qdrant.max_page() >= 100 * 4
    end

    test "id and match-any lists: 2x headroom over the largest list" do
      assert @strict["condition_max_size"] >= 2 * Qdrant.max_ids()
    end

    test "write batches: 2x headroom over the largest batch" do
      assert @strict["upsert_max_batchsize"] >= 2 * Qdrant.max_write_batch()
    end

    test "timeouts: every server timeout fits max_timeout" do
      assert Qdrant.server_timeout_s(:search) <= @strict["max_timeout"]
      assert Qdrant.server_timeout_s(:indexing) <= @strict["max_timeout"]
    end

    test "OrphanSweep and DEK rotation page at or under the declared maxima" do
      # Their page sizes are the declared maxima (or below); scroll/2 refuses
      # anything larger before it reaches Qdrant.
      assert_raise ArgumentError, fn ->
        Qdrant.scroll("c", filter: %{}, limit: Qdrant.max_page() + 1)
      end
    end
  end

  describe "call sites with unbounded inputs" do
    setup do
      bypass = Bypass.open()
      ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
      test_pid = self()

      Bypass.stub(bypass, "POST", "/collections/c/points/scroll", fn conn ->
        body = capture(conn, test_pid)
        ids = body |> get_in(["filter", "must"]) |> Enum.find_value(& &1["has_id"])
        points = Enum.map(ids || [], &%{"id" => &1})
        respond(conn, %{"result" => %{"points" => points, "next_page_offset" => nil}})
      end)

      Bypass.stub(bypass, "POST", "/collections/c/points/query", fn conn ->
        capture(conn, test_pid)
        respond(conn, %{"result" => %{"points" => []}})
      end)

      Bypass.stub(bypass, "POST", "/collections/c/points/query/batch", fn conn ->
        capture(conn, test_pid)
        respond(conn, %{"result" => [%{"points" => []}, %{"points" => []}]})
      end)

      Bypass.stub(bypass, "POST", "/collections/c/points", fn conn ->
        capture(conn, test_pid)
        respond(conn, %{"result" => []})
      end)

      :ok
    end

    @ids for i <- 1..20_000, do: "id-#{i}"

    test "dense_point_ids/2 over 20k ids" do
      assert {:ok, ids} = Qdrant.dense_point_ids("c", @ids)
      assert length(ids) == 20_000
      assert_all_within_limits()
    end

    test "recommend/3 over 20k ids, with every tenant filter set" do
      assert {:ok, []} = Qdrant.recommend("c", @ids, full_filters())
      assert_all_within_limits()
    end

    test "search, sparse_search and hybrid_search at the largest pool" do
      sparse = %{indices: [1, 2], values: [0.5, 0.5]}
      opts = Keyword.put(full_filters(), :limit, Qdrant.max_page())

      assert {:ok, _} = Qdrant.search("c", [0.1, 0.2], opts)
      assert {:ok, _} = Qdrant.sparse_search("c", sparse, opts)
      assert {:ok, _} = Qdrant.hybrid_search("c", [0.1, 0.2], sparse, opts)
      assert_all_within_limits()
    end
  end

  # Every filter the tenant filter can carry, at its largest.
  defp full_filters do
    [
      user_id: "u1",
      vault_id: for(i <- 1..Qdrant.max_ids(), do: "v#{i}"),
      tags_hmac: for(i <- 1..Qdrant.max_ids(), do: "t#{i}"),
      folder_hmac: "f",
      type_hmac: "ty",
      fm_timestamp_gte: 1,
      fm_timestamp_lte: 2,
      fm_created_gte: 1,
      fm_created_lte: 2,
      limit: 10
    ]
  end

  defp capture(conn, test_pid) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 100_000_000)
    conn = Plug.Conn.fetch_query_params(conn)
    body = Jason.decode!(raw)
    send(test_pid, {:qdrant_request, conn.request_path, conn.query_params, body})
    body
  end

  defp respond(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp assert_all_within_limits do
    requests = drain([])
    assert requests != [], "no Qdrant request was captured"

    for {path, params, body} <- requests do
      violations = violations(params, body)
      assert violations == [], "#{path} breaks strict mode: #{inspect(violations)}"
    end
  end

  defp drain(acc) do
    receive do
      {:qdrant_request, path, params, body} -> drain([{path, params, body} | acc])
    after
      0 -> acc
    end
  end

  defp violations(params, body) do
    searches = body["searches"] || [body]

    batch =
      if length(searches) > @strict["search_max_batchsize"], do: [{:batch, length(searches)}]

    timeout =
      case params["timeout"] do
        nil -> nil
        t -> if String.to_integer(t) > @strict["max_timeout"], do: [{:timeout, t}]
      end

    per_request = Enum.flat_map(searches, &request_violations/1)
    List.flatten([batch || [], timeout || [], per_request])
  end

  defp request_violations(req) do
    limit = req["limit"]
    filter = req["filter"]

    [
      if(is_integer(limit) and limit > @strict["max_query_limit"], do: {:limit, limit}),
      if(filter && condition_count(filter) > @strict["filter_max_conditions"],
        do: {:conditions, condition_count(filter)}
      ),
      for(
        size <- condition_sizes(filter),
        size > @strict["condition_max_size"],
        do: {:size, size}
      )
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  @clauses ~w(must must_not should)

  defp condition_count(%{} = filter) do
    filter
    |> Map.take(@clauses)
    |> Map.values()
    |> List.flatten()
    |> Enum.map(fn c -> if nested?(c), do: condition_count(c), else: 1 end)
    |> Enum.sum()
  end

  defp condition_sizes(nil), do: []

  defp condition_sizes(%{} = filter) do
    filter
    |> Map.take(@clauses)
    |> Map.values()
    |> List.flatten()
    |> Enum.flat_map(fn c ->
      cond do
        nested?(c) -> condition_sizes(c)
        is_list(c["has_id"]) -> [length(c["has_id"])]
        is_list(get_in(c, ["match", "any"])) -> [length(c["match"]["any"])]
        true -> []
      end
    end)
  end

  defp nested?(c), do: Enum.any?(@clauses, &Map.has_key?(c, &1))
end
