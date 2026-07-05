defmodule Engram.Sync.BroadcastFanoutSpanTest do
  @moduledoc """
  Fan-out span for the live-sync broadcast dispatch (Task 4).

  `sync.fanout` wraps the actual `Endpoint.broadcast`/`broadcast_from` call in
  `Engram.Sync.Broadcast` so the browser's render span (leg B) has a
  server-side parent distinct from the request span that produced the
  change (leg A). This asserts the span is actually recorded, not just that
  the broadcast still delivers.
  """
  use ExUnit.Case, async: false

  alias Engram.Sync.Broadcast

  require Record
  # Pull in the SDK span record so we can read exported fields.
  @fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @fields)

  setup do
    # Route exported spans to this process via the in-memory (pid) exporter,
    # same pattern as ClientSpanTest.
    :application.set_env(:opentelemetry, :traces_exporter, {:otel_exporter_pid, self()})
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    :ok
  end

  test "emit/3 wraps the immediate dispatch in a sync.fanout span" do
    topic = "sync:fanout-span-test-emit"
    EngramWeb.Endpoint.subscribe(topic)

    Broadcast.emit(topic, "note_changed", %{"id" => "n1"})

    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed"}

    assert_receive {:span, span_record}, 2_000
    s = span(span_record)
    assert s[:name] == "sync.fanout"
    assert :otel_attributes.map(s[:attributes])["engram.event_type"] == "note_changed"
  end

  test "a deferred flush wraps the eventual dispatch in a sync.fanout span" do
    topic = "sync:fanout-span-test-deferred"
    EngramWeb.Endpoint.subscribe(topic)

    Broadcast.deferred(fn ->
      Broadcast.emit(topic, "note_changed", %{"id" => "n2"})
      {:ok, :done}
    end)

    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed"}

    assert_receive {:span, span_record}, 2_000
    s = span(span_record)
    assert s[:name] == "sync.fanout"
  end

  test "emit_from/4 wraps the broadcast_from dispatch in a sync.fanout span" do
    topic = "sync:fanout-span-test-from"

    Broadcast.emit_from(self(), topic, "note_changed", %{"id" => "n3"})

    assert_receive {:span, span_record}, 2_000
    s = span(span_record)
    assert s[:name] == "sync.fanout"
    assert :otel_attributes.map(s[:attributes])["engram.event_type"] == "note_changed"
  end
end
