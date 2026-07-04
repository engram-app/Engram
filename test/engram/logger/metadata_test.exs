defmodule Engram.Logger.MetadataTest do
  use ExUnit.Case, async: true
  alias Engram.Logger.Metadata
  require OpenTelemetry.Tracer, as: Tracer

  test "stamps category and computed loki_ship for an info business event" do
    meta = Metadata.with_category(:info, :billing, paddle_subscription_id: "sub_1")
    assert meta[:category] == :billing
    assert meta[:loki_ship] == true
    assert meta[:paddle_subscription_id] == "sub_1"
  end

  test "routine info is tagged loki_ship false" do
    meta = Metadata.with_category(:info, :http, status: 200)
    assert meta[:loki_ship] == false
  end

  test "error always loki_ship true" do
    meta = Metadata.with_category(:error, :http, status: 500)
    assert meta[:loki_ship] == true
  end

  test "raises on unknown category to catch typos at the call site" do
    assert_raise ArgumentError, fn -> Metadata.with_category(:info, :nonsense, []) end
  end

  describe "with_category/3 trace correlation" do
    # NOTE: the task brief specified :websocket as the category, but that
    # atom does not exist in Engram.Logger.Category on this branch (it only
    # exists on the separate, unmerged origin/feat/ws-conn-tracing branch,
    # commit efc17bc0). Adding it here would require editing category.ex,
    # which is outside this task's file scope. Using :sync instead: it's an
    # existing valid category and is the one already used by the real-time
    # channel/websocket code in this branch (see crdt_channel.ex).
    test "adds hex trace_id and span_id when inside a span" do
      Tracer.with_span "test-span" do
        md = Metadata.with_category(:info, :sync, [])
        assert md[:trace_id] =~ ~r/\A[0-9a-f]{32}\z/
        assert md[:span_id] =~ ~r/\A[0-9a-f]{16}\z/
      end
    end

    test "omits trace_id/span_id when there is no active span" do
      md = Metadata.with_category(:info, :sync, [])
      refute Keyword.has_key?(md, :trace_id)
      refute Keyword.has_key?(md, :span_id)
    end
  end
end
