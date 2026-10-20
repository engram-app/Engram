defmodule Engram.Vector.QdrantStrictModeTest do
  @moduledoc """
  Prod runs Qdrant Cloud with strict mode ON (`unindexed_filtering_retrieve:
  false`), which rejects a filter on any payload field that has no index. The
  CI stack and staging run self-hosted Qdrant with strict mode OFF, and the
  Bypass suites answer 200 to anything, so #1609 (prod indexed four of the
  filter keys and 400'd folder, tag, type and date filters) could not fail a
  single test we had.

  This turns strict mode ON for one throwaway collection and filters on every
  key `Qdrant.search/3` can send. A key missing from `@payload_index_fields`
  fails here the way prod fails, not silently.
  """
  use ExUnit.Case, async: false

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  @moduletag :qdrant_integration

  @dims 8
  @vector List.duplicate(0.1, @dims)
  @user_id "11111111-1111-1111-1111-111111111111"
  @vault_id "22222222-2222-2222-2222-222222222222"
  @tag_hmac "dGFnLWhtYWM="

  setup do
    # Per-process override, NOT the global app env. 22 Bypass suites set
    # `:qdrant_url` globally and `Application.delete_env` it on exit, which
    # wipes the CI-provided URL for everything that runs after them: the client
    # then falls back to its compiled localhost:6333 default and every request
    # here dies with econnrefused against a perfectly healthy container.
    ServiceConfig.put_override(:qdrant_url, qdrant_url())

    # Partitioned like search_integration_test: one Qdrant, several BEAMs.
    col =
      "engram_strict_#{System.get_env("MIX_TEST_PARTITION")}_#{System.unique_integer([:positive])}"

    :ok = Qdrant.ensure_collection(col, @dims)
    :ok = enable_strict_mode(col)
    :ok = upsert_point(col)

    Engram.QdrantIntegration.drop_on_exit(col)

    %{col: col}
  end

  # Guards the guard: if strict mode were not actually enforced, every
  # assertion below would pass against an unindexed collection and this suite
  # would be decoration. An unindexed key must be rejected.
  test "strict mode is enforced: filtering an unindexed key is rejected", %{col: col} do
    body = %{
      query: @vector,
      using: "dense",
      filter: %{must: [%{key: "definitely_not_indexed", match: %{value: "x"}}]},
      limit: 1
    }

    {:ok, resp} = Req.post("#{qdrant_url()}/collections/#{col}/points/query", json: body)

    assert resp.status in 400..499,
           "strict mode is not enforcing: an unindexed filter returned #{resp.status}, " <>
             "so every other assertion in this file would pass vacuously"
  end

  test "every filter key Qdrant.search/3 sends has a payload index", %{col: col} do
    base = [user_id: @user_id, vault_id: @vault_id, limit: 1]

    cases = [
      {"user_id + vault_id", []},
      {"folder_hmac", [folder_hmac: "Zm9sZGVyLWhtYWM="]},
      {"tags_hmac", [tags_hmac: [@tag_hmac]]},
      {"type_hmac", [type_hmac: "dHlwZS1obWFj"]},
      {"fm_timestamp range", [fm_timestamp_gte: 0, fm_timestamp_lte: 2_000_000_000]},
      {"fm_created range", [fm_created_gte: 0, fm_created_lte: 2_000_000_000]}
    ]

    for {label, opts} <- cases do
      assert {:ok, _results} = Qdrant.search(col, @vector, base ++ opts),
             "#{label}: strict mode rejected this filter, so its payload index is missing. " <>
               "Add the key to @payload_index_fields (keyword) or " <>
               "@integer_payload_index_fields (integer) in lib/engram/vector/qdrant.ex."
    end
  end

  test "path_hmac, the delete filter key, is indexed too", %{col: col} do
    # `delete_by_note/4` filters on path_hmac. Under strict mode an unindexed
    # key fails the DELETE, which would strand a deleted note's points.
    assert :ok = Qdrant.delete_by_note(col, @user_id, @vault_id, "cGF0aC1obWFj")
  end

  # The Cloud hard limits on a real server (review H1): Qdrant applies
  # max_query_limit to scroll and sizes has_id / match.any by their length,
  # neither of which a Bypass stub can show. Every call at its largest must
  # pass the server's own verification.
  describe "under the Qdrant Cloud hard limits" do
    setup %{col: col} do
      {:ok, %{status: 200}} =
        Req.patch("#{qdrant_url()}/collections/#{col}",
          json: %{strict_mode_config: Engram.Vector.QdrantLayout.desired_strict(:cloud)}
        )

      :ok
    end

    test "the largest scroll page, has_id lists and tenant filter all fit", %{col: col} do
      ids = for _ <- 1..(Qdrant.max_ids() * 3), do: Ecto.UUID.generate()
      assert {:ok, []} = Qdrant.dense_point_ids(col, ids)

      assert {:ok, %{points: _}} =
               Qdrant.scroll(col,
                 filter: %{must: [%{has_id: Enum.take(ids, Qdrant.max_ids())}]},
                 with_payload: false,
                 limit: Qdrant.max_page()
               )

      opts = [
        user_id: @user_id,
        vault_id: for(_ <- 1..Qdrant.max_ids(), do: Ecto.UUID.generate()),
        tags_hmac: for(i <- 1..Qdrant.max_ids(), do: "t#{i}"),
        folder_hmac: "Zm9sZGVyLWhtYWM=",
        fm_timestamp_gte: 0,
        limit: Qdrant.max_page()
      ]

      assert {:ok, _} = Qdrant.search(col, @vector, opts)
      assert {:ok, _} = Qdrant.hybrid_search(col, @vector, %{indices: [1], values: [1.0]}, opts)
    end

    test "the kill switch PATCH is accepted and lifts every limit", %{col: col} do
      off = Engram.Vector.QdrantLayout.desired(Version.parse!("1.19.2"), nil, false, :cloud)

      {:ok, %{status: 200}} =
        Req.patch("#{qdrant_url()}/collections/#{col}",
          json: Map.take(off, ["strict_mode_config"])
        )

      {:ok, %{status: 200, body: %{"result" => info}}} =
        Req.get("#{qdrant_url()}/collections/#{col}")

      applied = info["config"]["strict_mode_config"]
      assert applied["max_query_limit"] == 2_147_483_647
      assert applied["max_points_count"] == 2_147_483_647
      assert applied["max_collection_vector_size_bytes"] == 2 ** 53 - 1
    end
  end

  defp upsert_point(col) do
    Qdrant.upsert_points(col, [
      %{
        id: Ecto.UUID.generate(),
        vector: %{"dense" => @vector},
        payload: %{
          user_id: @user_id,
          vault_id: @vault_id,
          note_id: Ecto.UUID.generate(),
          path_hmac: "cGF0aC1obWFj",
          folder_hmac: "Zm9sZGVyLWhtYWM=",
          tags_hmac: [@tag_hmac],
          type_hmac: "dHlwZS1obWFj",
          fm_timestamp: 1_700_000_000,
          fm_created: 1_600_000_000
        }
      }
    ])
  end

  defp enable_strict_mode(col) do
    {:ok, %{status: 200}} =
      Req.patch("#{qdrant_url()}/collections/#{col}",
        json: %{strict_mode_config: %{enabled: true, unindexed_filtering_retrieve: false}}
      )

    :ok
  end

  defp qdrant_url do
    System.get_env("QDRANT_URL") ||
      Application.get_env(:engram, :qdrant_url, "http://localhost:6333")
  end
end
