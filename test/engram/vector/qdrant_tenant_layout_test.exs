defmodule Engram.Vector.QdrantTenantLayoutTest do
  @moduledoc """
  Task 8.1 against a real Qdrant (CI pins 1.19.2): a collection created with
  the tenant layout reads back as no drift, so a boot sends no PATCH, and
  every payload index comes back with the schema it was created with. Bypass
  answers 200 to anything, so only a real server proves the 1.19.2 API takes
  `is_tenant` on a `uuid` index, `enable_hnsw: false` and `m: 0`.
  """
  use ExUnit.Case, async: false

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant
  alias Engram.Vector.QdrantLayout

  @moduletag :qdrant_integration

  @dims 8
  @user "11111111111111111111111111111111"
  @other "33333333333333333333333333333333"

  setup do
    ServiceConfig.put_override(:qdrant_url, qdrant_url())
    ServiceConfig.put_override(:qdrant_reconcile_config, true)
    ServiceConfig.put_override(:v5_payload_format, true)

    col =
      "engram_tenant_#{System.get_env("MIX_TEST_PARTITION")}_#{System.unique_integer([:positive])}"

    version = Qdrant.server_version()
    :ok = Qdrant.ensure_collection(col, @dims)
    Engram.QdrantIntegration.drop_on_exit(col)

    %{col: col, version: version}
  end

  test "created with the desired layout, the GET round-trips: no drift, no PATCH", ctx do
    assert QdrantLayout.tenant_layout?(ctx.version),
           "CI pins Qdrant 1.19.2; got #{inspect(ctx.version)}"

    {:ok, info} = Qdrant.collection_info(ctx.col)

    want = QdrantLayout.desired(ctx.version)
    assert Map.drop(QdrantLayout.diff(info["config"], want), ["strict_mode_config"]) == %{}
    assert info["config"]["hnsw_config"]["m"] == 0

    for {field, schema} <- QdrantLayout.payload_indexes(ctx.version, true) do
      have = info["payload_schema"][field]["params"]
      assert Enum.all?(schema, fn {k, v} -> have[k] == v end), "#{field}: #{inspect(have)}"
    end

    refute Map.has_key?(info["payload_schema"], "note_id")

    # The boot after creation (strict mode applied by the first) is a no-op.
    assert {:ok, []} = Qdrant.reconcile_config(ctx.col)
  end

  test "a tenant-filtered dense search finds only that tenant's points", %{col: col} do
    :ok =
      Qdrant.upsert_points(col, [
        point(1, @user, 0.1),
        point(2, @other, 0.1)
      ])

    filter = %{"must" => [%{"key" => "u", "match" => %{"value" => @user}}]}

    {:ok, %{status: 200, body: %{"result" => %{"points" => hits}}}} =
      Req.post("#{qdrant_url()}/collections/#{col}/points/query",
        json: %{query: List.duplicate(0.1, @dims), using: "dense", filter: filter}
      )

    assert Enum.map(hits, & &1["id"]) == [uuid(1)]
  end

  defp point(n, user, x),
    do: %{id: uuid(n), vector: %{"dense" => List.duplicate(x, @dims)}, payload: %{"u" => user}}

  defp uuid(n), do: "00000000-0000-0000-0000-00000000000#{n}"

  defp qdrant_url do
    System.get_env("QDRANT_URL") ||
      Application.get_env(:engram, :qdrant_url, "http://localhost:6333")
  end
end
