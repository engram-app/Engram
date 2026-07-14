defmodule Engram.Notes.FanoutPacerTest do
  # async: false — shares the named FanoutPacer process + global ETS + app env.
  use ExUnit.Case, async: false

  alias Engram.Notes.FanoutPacer

  setup do
    prev = Application.get_all_env(:engram)

    on_exit(fn ->
      Application.put_env(:engram, :fanout_pacing_enabled, prev[:fanout_pacing_enabled])
      Application.put_env(:engram, :fanout_hot_window_ms, prev[:fanout_hot_window_ms])
      Application.put_env(:engram, :fanout_drain_batch, prev[:fanout_drain_batch])
      Application.put_env(:engram, :fanout_drain_interval_ms, prev[:fanout_drain_interval_ms])
    end)

    FanoutPacer.reset()
    :ok
  end

  defp payload(note_id), do: %{"note_id" => note_id, "b64" => "x", "head" => "h"}

  test "when pacing disabled, emit/4 broadcasts inline immediately" do
    Application.put_env(:engram, :fanout_pacing_enabled, false)
    topic = "sync:u1:v1"
    EngramWeb.Endpoint.subscribe(topic)

    FanoutPacer.emit(topic, "note_yjs_update", payload("n1"), "n1")

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "note_yjs_update",
                     payload: %{"note_id" => "n1"}
                   },
                   200
  end

  test "cold flood drains in batches over ticks, not all at once" do
    Application.put_env(:engram, :fanout_pacing_enabled, true)
    Application.put_env(:engram, :fanout_hot_window_ms, 60_000)
    Application.put_env(:engram, :fanout_drain_batch, 3)
    Application.put_env(:engram, :fanout_drain_interval_ms, 50)

    topic = "sync:u2:v2"
    EngramWeb.Endpoint.subscribe(topic)

    # 7 distinct COLD notes (each note_id touched once → all cold).
    for i <- 1..7, do: FanoutPacer.emit(topic, "note_yjs_update", payload("c#{i}"), "c#{i}")

    # First tick delivers exactly drain_batch (3), then no more until next tick.
    for _ <- 1..3, do: assert_receive(%Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 200)
    refute_receive %Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 20

    # Remaining 4 drain over the following ticks.
    for _ <- 1..4, do: assert_receive(%Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 300)
    refute_receive %Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 100
  end

  test "hot frame bypasses and arrives before the bulk of a concurrent cold flood (#1002)" do
    Application.put_env(:engram, :fanout_pacing_enabled, true)
    Application.put_env(:engram, :fanout_hot_window_ms, 60_000)
    Application.put_env(:engram, :fanout_drain_batch, 1)
    Application.put_env(:engram, :fanout_drain_interval_ms, 80)

    topic = "sync:u3:v3"
    EngramWeb.Endpoint.subscribe(topic)

    # Warm note "live" so it is HOT (seen within the window). This first frame is
    # cold (paced), so drain it before asserting the bypass on the SECOND frame.
    FanoutPacer.emit(topic, "note_yjs_update", payload("live"), "live")
    assert_receive(%Phoenix.Socket.Broadcast{payload: %{"note_id" => "live"}}, 300)

    # A big genesis flood of distinct COLD notes.
    for i <- 1..20, do: FanoutPacer.emit(topic, "note_yjs_update", payload("g#{i}"), "g#{i}")

    # The live note edits again → HOT → must arrive immediately, not behind the 20.
    FanoutPacer.emit(topic, "note_yjs_update", payload("live"), "live")
    assert_receive(%Phoenix.Socket.Broadcast{payload: %{"note_id" => "live"}}, 60)
  end

  test "two topics drain independently (per-vault fairness)" do
    Application.put_env(:engram, :fanout_pacing_enabled, true)
    Application.put_env(:engram, :fanout_hot_window_ms, 60_000)
    Application.put_env(:engram, :fanout_drain_batch, 1)
    Application.put_env(:engram, :fanout_drain_interval_ms, 50)

    ta = "sync:u4:va"
    tb = "sync:u4:vb"
    EngramWeb.Endpoint.subscribe(ta)
    EngramWeb.Endpoint.subscribe(tb)

    FanoutPacer.emit(ta, "note_yjs_update", payload("a1"), "a1")
    FanoutPacer.emit(tb, "note_yjs_update", payload("b1"), "b1")

    # Both topics get a frame within the first tick (not serialized behind each other).
    assert_receive(%Phoenix.Socket.Broadcast{topic: ^ta}, 200)
    assert_receive(%Phoenix.Socket.Broadcast{topic: ^tb}, 200)
  end
end
