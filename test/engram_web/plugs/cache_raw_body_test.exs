defmodule EngramWeb.Plugs.CacheRawBodyTest do
  @moduledoc """
  The body read gets its own span (2026-10-24 speed audit). Slow POSTs showed
  0.5-15 s before their first DB query with no child span: the request
  process was parked in `Plug.Conn.read_body`, waiting on a client that had
  not sent its body yet. Without this span that wait is invisible.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias EngramWeb.Plugs.CacheRawBody

  require Record
  @fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @fields)

  setup do
    :application.set_env(:opentelemetry, :traces_exporter, {:otel_exporter_pid, self()})
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    :ok
  end

  defp body_read_span do
    assert_receive {:span, span(name: "http.request.body_read") = record}, 2_000
    :otel_attributes.map(span(record, :attributes))
  end

  test "read_body/2 caches the body and records its size on a body_read span" do
    assert {:ok, "hello", conn} = CacheRawBody.read_body(conn(:post, "/", "hello"), [])
    assert conn.assigns.raw_body == "hello"
    assert %{"http.request.body.size": 5, "engram.body_read.result": "ok"} = body_read_span()
  end

  test "a partial read is recorded as :more with the bytes it got" do
    body = String.duplicate("a", 100)
    assert {:more, chunk, _conn} = CacheRawBody.read_body(conn(:post, "/", body), length: 10)
    attrs = body_read_span()
    assert attrs[:"http.request.body.size"] == byte_size(chunk)
    assert attrs[:"engram.body_read.result"] == "more"
  end

  test "an empty body is a zero-byte span" do
    assert {:ok, "", _conn} = CacheRawBody.read_body(conn(:post, "/", ""), [])
    assert %{"http.request.body.size": 0} = body_read_span()
  end
end
