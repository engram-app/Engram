defmodule Engram.Vector.QdrantTenantLayoutTest do
  @moduledoc """
  Task 8.1 against a real Qdrant (CI pins 1.19.2): a collection created with
  the tenant layout reads back as no drift, so a boot sends no PATCH, and
  every payload index comes back with the schema it was created with. Bypass
  answers 200 to anything, so only a real server proves the 1.19.2 API takes
  `is_tenant` on a `uuid` index and `enable_hnsw: false`.
  """
  use ExUnit.Case, async: false

  alias Engram.ServiceConfig
  alias Engram.Vector.FilterId
  alias Engram.Vector.Qdrant
  alias Engram.Vector.QdrantLayout

  @moduletag :qdrant_integration

  @dims 8
  @user "11111111-1111-1111-1111-111111111111"
  @vault "22222222-2222-2222-2222-222222222222"

  setup do
    ServiceConfig.put_override(:qdrant_url, qdrant_url())
    ServiceConfig.put_override(:qdrant_reconcile_config, true)
    ServiceConfig.put_override(:v5_payload_format, true)
    %{version: Qdrant.server_version()}
  end

  # Each test makes only its own collection: every one costs ~2 MB per
  # payload index per segment on CI's 2 GB tmpfs Qdrant.
  defp collection!(prefix, dims) do
    col =
      "#{prefix}_#{System.get_env("MIX_TEST_PARTITION")}_#{System.unique_integer([:positive])}"

    # Before the create, so a half-made collection is dropped too.
    Engram.QdrantIntegration.drop_on_exit(col)
    :ok = Qdrant.ensure_collection(col, dims)
    col
  end

  test "created with the desired layout, the GET round-trips: no drift, no PATCH", ctx do
    col = collection!("engram_tenant", @dims)

    assert QdrantLayout.tenant_layout?(ctx.version),
           "CI pins Qdrant 1.19.2; got #{inspect(ctx.version)}"

    {:ok, info} = Qdrant.collection_info(col)

    want = QdrantLayout.desired(ctx.version)
    assert Map.drop(QdrantLayout.diff(info["config"], want), ["strict_mode_config"]) == %{}

    # The global graph stays while legacy and v5 points coexist (Task 18.1).
    assert info["config"]["hnsw_config"]["m"] == 16

    for {field, schema} <- QdrantLayout.payload_indexes(ctx.version, true) do
      have = info["payload_schema"][field]["params"]
      assert Enum.all?(schema, fn {k, v} -> have[k] == v end), "#{field}: #{inspect(have)}"
    end

    refute Map.has_key?(info["payload_schema"], "note_id")
    assert QdrantLayout.tenant_graph?(info, ctx.version, true)

    # The boot after creation (strict mode applied by the first) is a no-op.
    assert {:ok, []} = Qdrant.reconcile_config(col)
  end

  # One user's points in BOTH formats during the pass (legacy `user_id`, v5
  # `u`), more of them than full_scan_threshold, so Qdrant searches the HNSW
  # graph rather than scanning the payload index. With the global graph
  # (m 16) the tenant filter's `should` over both formats must find exactly
  # what an exact search finds.
  #
  # Thresholds are per segment and in KB of vectors (Qdrant default segment
  # count is the CPU count), so the vectors must be wide enough that each
  # segment's share of 3000 points clears both: 256 dims at f16 is 0.5 KB a
  # point, about 190 KB per segment on 8 segments, against 10 KB.
  @n 3000
  @wide 256

  @tag timeout: 120_000
  test "mixed-format tenant search over the graph equals exact search" do
    col = collection!("engram_tenant_graph", @wide)

    patch!(col, %{
      hnsw_config: %{full_scan_threshold: 10},
      optimizers_config: %{indexing_threshold: 10}
    })

    :rand.seed(:exsss, {1, 2, 3})

    @n
    |> points()
    |> Enum.chunk_every(500)
    |> Enum.each(fn batch ->
      {:ok, %{status: 200}} =
        Req.put("#{qdrant_url()}/collections/#{col}/points?wait=true", json: %{points: batch})
    end)

    wait_indexed!(col, @n)

    filter = Qdrant.build_tenant_filter(user_id: @user, vault_id: @vault)
    query = vector(@wide)

    approx = top(col, query, filter, %{hnsw_ef: 128, quantization: %{ignore: true}})
    exact = top(col, query, filter, %{exact: true, quantization: %{ignore: true}})

    assert length(exact) == 20
    assert approx == exact

    # Both formats are in the answer, or the test proves one subgraph only.
    assert Enum.any?(exact, &(&1 <= div(@n, 2)))
    assert Enum.any?(exact, &(&1 > div(@n, 2)))
  end

  defp points(n) do
    for i <- 1..n do
      payload =
        if i <= div(n, 2),
          do: %{"user_id" => @user, "vault_id" => @vault},
          else: %{"u" => FilterId.uuid(@user), "v" => FilterId.uuid(@vault)}

      %{id: i, vector: %{"dense" => vector(@wide)}, payload: payload}
    end
  end

  defp vector(dims), do: for(_ <- 1..dims, do: :rand.uniform() - 0.5)

  defp top(col, query, filter, params) do
    {:ok, %{status: 200, body: %{"result" => %{"points" => hits}}}} =
      Req.post("#{qdrant_url()}/collections/#{col}/points/query",
        json: %{query: query, using: "dense", filter: filter, limit: 20, params: params}
      )

    Enum.map(hits, & &1["id"])
  end

  defp patch!(col, body) do
    {:ok, %{status: 200}} = Req.patch("#{qdrant_url()}/collections/#{col}", json: body)
  end

  # The optimizer builds the graph in the background; wait until every
  # vector sits in an indexed segment.
  defp wait_indexed!(col, n, tries \\ 180) do
    {:ok, info} = Qdrant.collection_info(col)

    cond do
      info["status"] == "green" and (info["indexed_vectors_count"] || 0) >= n ->
        :ok

      tries == 0 ->
        flunk("graph never built: #{inspect(Map.take(info, ~w(status indexed_vectors_count)))}")

      true ->
        Process.sleep(500)
        wait_indexed!(col, n, tries - 1)
    end
  end

  defp qdrant_url do
    System.get_env("QDRANT_URL") ||
      Application.get_env(:engram, :qdrant_url, "http://localhost:6333")
  end
end
