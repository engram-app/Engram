defmodule Engram.Sync.BroadcastTest do
  use ExUnit.Case, async: true

  alias Engram.Sync.Broadcast

  @topic "sync:broadcast-test"

  setup do
    EngramWeb.Endpoint.subscribe(@topic)
    :ok
  end

  test "emit/3 broadcasts immediately when no deferral is active (OFF by default)" do
    assert :ok = Broadcast.emit(@topic, "note_changed", %{"n" => 1})

    assert_receive %Phoenix.Socket.Broadcast{
      topic: @topic,
      event: "note_changed",
      payload: %{"n" => 1}
    }
  end

  test "deferred/1 flushes buffered events in order on {:ok, _}" do
    result =
      Broadcast.deferred(fn ->
        Broadcast.emit(@topic, "note_changed", %{"n" => 1})
        Broadcast.emit(@topic, "note_changed", %{"n" => 2})
        # Nothing delivered yet — still buffered.
        refute_received %Phoenix.Socket.Broadcast{topic: @topic}
        {:ok, :done}
      end)

    assert result == {:ok, :done}
    # Flushed post-commit, in emission order.
    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: %{"n" => 1}}
    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: %{"n" => 2}}
  end

  test "deferred/1 discards buffered events on {:error, _} (rollback)" do
    result =
      Broadcast.deferred(fn ->
        Broadcast.emit(@topic, "note_changed", %{"n" => 1})
        {:error, :conflict}
      end)

    assert result == {:error, :conflict}
    refute_receive %Phoenix.Socket.Broadcast{topic: @topic}, 50
  end

  test "deferred/1 clears the buffer so a later emit broadcasts immediately again" do
    Broadcast.deferred(fn -> {:error, :nope} end)

    Broadcast.emit(@topic, "note_changed", %{"after" => true})
    assert_receive %Phoenix.Socket.Broadcast{payload: %{"after" => true}}
  end
end
