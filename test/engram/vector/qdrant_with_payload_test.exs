defmodule Engram.Vector.QdrantWithPayloadTest do
  @moduledoc """
  Task 15.8: every ranked search body asks for no payload (search reads the
  text from Postgres); only the text fallback names payload keys
  (`Qdrant.fallback_payload/0`). No body asks for the whole payload.
  """
  use ExUnit.Case, async: true

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  @text_keys ~w(text title heading_path source_path tags text_nonce title_nonce
                heading_path_nonce aad_version)
  @sparse %{indices: [1], values: [0.5]}

  defp bodies(opts) do
    opts = [user_id: "u1"] ++ opts

    [
      Qdrant.search_body([0.1], opts),
      Qdrant.sparse_search_body(@sparse, opts),
      Qdrant.recommend_body(["p1"], opts)
    ]
  end

  test "the fallback include list: the v3/v4 text keys and u" do
    assert Qdrant.fallback_payload() == @text_keys ++ ["u"]
  end

  test "every ranked body asks for no payload and no vectors" do
    for body <- bodies([]) do
      assert body.with_payload == false
      refute Map.has_key?(body, :with_vector)
    end
  end

  test "with_vector (MMR) puts the dense vector on the pool query itself" do
    for body <- bodies(with_vector: true), do: assert(body.with_vector == ["dense"])
  end

  test "hybrid legs carry ids and scores only" do
    body = Qdrant.hybrid_search_body([0.1], @sparse, user_id: "u1", with_vector: true)

    for leg <- body.searches do
      assert leg.with_payload == false
      refute Map.has_key?(leg, :with_vector)
    end
  end

  describe "retrieve/3" do
    setup do
      bypass = Bypass.open()
      ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
      ServiceConfig.put_override(:qdrant_search_timeout, 30_000)
      %{bypass: bypass}
    end

    defp expect_retrieve(bypass, result) do
      pid = self()

      Bypass.expect_once(bypass, "POST", "/collections/c/points", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(pid, {:body, Jason.decode!(raw)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => result}))
      end)
    end

    test "vectors: the dense vector and no payload", %{bypass: bypass} do
      expect_retrieve(bypass, [%{"id" => "a", "vector" => %{"dense" => [1.0]}}])

      assert {:ok, [%{qdrant_id: "a", vector: [1.0]}]} =
               Qdrant.retrieve("c", ["a"], with_vector: true)

      assert_received {:body,
                       %{"ids" => ["a"], "with_payload" => false, "with_vector" => ["dense"]}}
    end

    test "payload: the named keys and no vectors", %{bypass: bypass} do
      expect_retrieve(bypass, [%{"id" => "a", "payload" => %{"text" => "t"}}])

      assert {:ok, [%{qdrant_id: "a", text: "t"}]} =
               Qdrant.retrieve("c", ["a"], with_payload: ["text"])

      assert_received {:body, body}
      assert body == %{"ids" => ["a"], "with_payload" => ["text"]}
    end

    test "no ids, no request" do
      assert {:ok, []} = Qdrant.retrieve("c", [], with_vector: true)
    end
  end
end
