defmodule Engram.Vector.QdrantWithPayloadTest do
  @moduledoc """
  Task 15.8: one accessor (`Qdrant.result_payload/1`) decides the payload
  include list of every search body, for both `:chunk_text_read` states and
  both payload formats; no body asks for the whole payload or for vectors.
  """
  use ExUnit.Case, async: true

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  @text_keys ~w(text title heading_path source_path tags text_nonce title_nonce
                heading_path_nonce aad_version)
  @sparse %{indices: [1], values: [0.5]}

  defp bodies(opts) do
    opts = [user_id: "u1", with_vector: true] ++ opts

    [
      Qdrant.search_body([0.1], opts),
      Qdrant.sparse_search_body(@sparse, opts),
      Qdrant.recommend_body(["p1"], opts)
    ]
  end

  test "the include list per text source and payload format" do
    ServiceConfig.put_override(:v5_payload_format, false)
    assert Qdrant.result_payload(:payload) == ["vault_id" | @text_keys]
    assert Qdrant.result_payload(:fallback) == @text_keys
    assert Qdrant.result_payload(:postgres) == false

    ServiceConfig.put_override(:v5_payload_format, true)
    assert Qdrant.result_payload(:payload) == ["vault_id" | @text_keys] ++ ["u"]
    assert Qdrant.result_payload(:fallback) == @text_keys ++ ["u"]
    assert Qdrant.result_payload(:postgres) == false
  end

  for v5? <- [false, true] do
    test "chunk_text_read off, v5 #{v5?}: the text keys and vault_id, no vectors" do
      ServiceConfig.put_override(:v5_payload_format, unquote(v5?))

      for body <- bodies(chunk_text_read: false) do
        assert body.with_payload == Qdrant.result_payload(:payload)
        refute Map.has_key?(body, :with_vector)
      end
    end

    test "chunk_text_read on, v5 #{v5?}: no payload, no vectors" do
      ServiceConfig.put_override(:v5_payload_format, unquote(v5?))

      for body <- bodies(chunk_text_read: true) do
        assert body.with_payload == false
        refute Map.has_key?(body, :with_vector)
      end
    end
  end

  test "hybrid legs carry ids and scores only" do
    for read? <- [false, true] do
      body = Qdrant.hybrid_search_body([0.1], @sparse, user_id: "u1", chunk_text_read: read?)

      for leg <- body.searches do
        assert leg.with_payload == false
        refute Map.has_key?(leg, :with_vector)
      end
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
