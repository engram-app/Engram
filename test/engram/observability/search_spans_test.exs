defmodule Engram.Observability.SearchSpansTest do
  @moduledoc """
  The two network legs of a search, the Voyage embed and the Qdrant query,
  each get their own span, carrying no query text or vector.
  """
  use ExUnit.Case, async: false

  alias Engram.Embedders.Voyage
  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  require Record
  @fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @fields)

  setup do
    :application.set_env(:opentelemetry, :traces_exporter, {:otel_exporter_pid, self()})
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    bypass = Bypass.open()
    %{bypass: bypass}
  end

  test "Voyage embed runs in a voyage.embed span", %{bypass: bypass} do
    ServiceConfig.put_override(:voyage_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:voyage_api_key, "test-key")

    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"data":[{"embedding":[0.1]}]}))
    end)

    assert {:ok, [[0.1]]} = Voyage.embed_texts(["secret query"], purpose: :query)
    assert_receive {:span, span(name: "voyage.embed", attributes: attrs)}, 2_000
    attrs = :otel_attributes.map(attrs)
    assert attrs["engram.embed.purpose"] == "query"
    refute inspect(attrs) =~ "secret query"
  end

  test "Qdrant points/query runs in a qdrant.query span", %{bypass: bypass} do
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:qdrant_search_timeout, 30_000)

    Bypass.expect_once(bypass, "POST", "/collections/c1/points/query", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result":{"points":[]}}))
    end)

    assert {:ok, []} = Qdrant.search("c1", [0.1], user_id: "u1", limit: 5)
    assert_receive {:span, span(name: "qdrant.query")}, 2_000
  end

  test "a non-2xx Voyage reply marks the span as an error", %{bypass: bypass} do
    ServiceConfig.put_override(:voyage_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:voyage_api_key, "test-key")

    Bypass.expect(bypass, "POST", "/v1/embeddings", fn conn ->
      Plug.Conn.send_resp(conn, 400, ~s({"detail":"bad"}))
    end)

    assert {:error, _} = Voyage.embed_texts(["q"], purpose: :query)
    assert_receive {:span, span(name: "voyage.embed", status: {:status, :error, msg})}, 2_000
    assert msg == "http 400"
  end

  test "a 2xx Qdrant reply leaves the span unset; a transport error marks it", %{
    bypass: bypass
  } do
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:qdrant_search_timeout, 30_000)

    Bypass.expect_once(bypass, "POST", "/collections/c1/points/query", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result":{"points":[]}}))
    end)

    assert {:ok, []} = Qdrant.search("c1", [0.1], user_id: "u1", limit: 5)
    assert_receive {:span, span(name: "qdrant.query", status: status)}, 2_000
    refute match?({:status, :error, _}, status)

    Bypass.down(bypass)
    assert {:error, _} = Qdrant.search("c1", [0.1], user_id: "u1", limit: 5)
    assert_receive {:span, span(name: "qdrant.query", status: {:status, :error, msg})}, 2_000
    assert msg =~ "transport"
  end
end
