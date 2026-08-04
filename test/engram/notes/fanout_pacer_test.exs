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

  # Block until the pacer has broadcast everything queued for `topic`.
  #
  # Polls a condition instead of sleeping a guessed interval: handle_info(:drain)
  # broadcasts synchronously and then rebuilds its queue map without the emptied
  # topics, so the topic key being absent means those frames are already out.
  # Bounded so a pacer that never drains fails loudly instead of hanging.
  defp await_drained(topic, tries \\ 200) do
    cond do
      not Map.has_key?(:sys.get_state(FanoutPacer).queues, topic) ->
        :ok

      tries == 0 ->
        flunk("FanoutPacer never drained #{topic}")

      true ->
        Process.sleep(10)
        await_drained(topic, tries - 1)
    end
  end

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
    # 200ms interval keeps the post-batch refute window (100ms) a safe fraction
    # of the inter-tick gap, so scheduler jitter + assert-completion drift under
    # CI load cannot overlap the next tick (a tight 50ms interval flaked here).
    Application.put_env(:engram, :fanout_drain_interval_ms, 200)

    topic = "sync:u2:v2"
    EngramWeb.Endpoint.subscribe(topic)

    # 7 distinct COLD notes (each note_id touched once → all cold).
    for i <- 1..7, do: FanoutPacer.emit(topic, "note_yjs_update", payload("c#{i}"), "c#{i}")

    # First tick delivers exactly drain_batch (3), then no more until next tick.
    for _ <- 1..3, do: assert_receive(%Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 600)
    refute_receive %Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 100

    # Remaining 4 drain over the following ticks.
    for _ <- 1..4, do: assert_receive(%Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 800)
    refute_receive %Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 200
  end

  test "hot frame bypasses and arrives before the bulk of a concurrent cold flood (#1002)" do
    Application.put_env(:engram, :fanout_pacing_enabled, true)
    Application.put_env(:engram, :fanout_hot_window_ms, 60_000)
    Application.put_env(:engram, :fanout_drain_batch, 1)
    Application.put_env(:engram, :fanout_drain_interval_ms, 80)

    topic = "sync:u3:v3"

    # Warm note "live" so it is HOT (seen within the window). Hotness is written
    # by cold?/1 during emit, but this first frame is itself cold, so the pacer
    # queues it and broadcasts it on a drain tick.
    #
    # Subscribe only AFTER that frame is gone. Waiting for it in the mailbox
    # instead put a drain tick — load-variable work — inside a timed assert, and
    # under full-suite concurrency it landed just past the window (this is the
    # flake). Emitting before subscribing keeps the warm-up out of the mailbox
    # entirely, so the assert below can only ever match the bypass frame.
    #
    # Note the warm-up MUST be paced: emit/4 short-circuits on
    # `pacing_enabled?() and cold?(note_id)`, so warming with pacing disabled
    # would skip cold?/1, never mark the note seen, and leave it COLD.
    FanoutPacer.emit(topic, "note_yjs_update", payload("live"), "live")
    await_drained(topic)
    EngramWeb.Endpoint.subscribe(topic)

    # A big genesis flood of distinct COLD notes.
    for i <- 1..20, do: FanoutPacer.emit(topic, "note_yjs_update", payload("g#{i}"), "g#{i}")

    # The live note edits again → HOT → must arrive immediately, not behind the 20.
    # 150ms proves bypass with margin: the cold backlog (batch=1 @ 80ms = 1600ms
    # to drain) means anything under a few hundred ms can only be the inline hot
    # frame, so a generous ceiling keeps the assert robust without weakening it.
    FanoutPacer.emit(topic, "note_yjs_update", payload("live"), "live")
    assert_receive(%Phoenix.Socket.Broadcast{payload: %{"note_id" => "live"}}, 150)
  end

  # Pins the emitter side of the #1004 gauges. Engram.PromEx.Reliability reads
  # these measurement keys by name, so renaming one here would leave the prod
  # dashboards reporting nothing — silently, and exactly when a queue is
  # backing up. The metric-shape test cannot catch that; only this can.
  test "drain tick emits the cold-queue measurements the PromEx gauges read" do
    Application.put_env(:engram, :fanout_pacing_enabled, true)
    Application.put_env(:engram, :fanout_hot_window_ms, 60_000)
    Application.put_env(:engram, :fanout_drain_batch, 1)
    Application.put_env(:engram, :fanout_drain_interval_ms, 20)

    ref = make_ref()
    parent = self()

    :telemetry.attach(
      "pacer-drain-#{inspect(ref)}",
      [:engram, :fanout_pacer, :drain],
      fn _event, measurements, _meta, _cfg -> send(parent, {ref, measurements}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("pacer-drain-#{inspect(ref)}") end)

    topic = "sync:u6:v6"
    for i <- 1..3, do: FanoutPacer.emit(topic, "note_yjs_update", payload("m#{i}"), "m#{i}")

    assert_receive {^ref, measurements}, 1_000
    assert %{queued: _, max_topic_depth: _, topics: _} = measurements

    # A backlog is still pending on the first tick (3 frames, batch of 1), so
    # this also proves the gauge reports a real level rather than a constant 0.
    assert measurements.max_topic_depth > 0
    assert measurements.topics > 0

    # Drain fully before finishing. The module shares one named pacer, and the
    # drain loop only stops rescheduling once its queues empty — leaving frames
    # behind would keep a 20ms timer alive into the NEXT test, which sets a
    # slower interval and asserts on tick spacing. That stale timer fires
    # inside its refute window and fails it (observed, not hypothetical).
    await_drained(topic)
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

  test "test_drop_next/2 swallows exactly n emits for that note, then resumes" do
    Application.put_env(:engram, :fanout_pacing_enabled, false)
    topic = "sync:u5:v1"
    EngramWeb.Endpoint.subscribe(topic)

    FanoutPacer.test_drop_next("doomed", 2)

    FanoutPacer.emit(topic, "note_yjs_update", payload("doomed"), "doomed")
    FanoutPacer.emit(topic, "note_yjs_update", payload("other"), "other")
    FanoutPacer.emit(topic, "note_yjs_update", payload("doomed"), "doomed")
    FanoutPacer.emit(topic, "note_yjs_update", payload("doomed"), "doomed")

    # Other notes are untouched; the armed note loses exactly 2 frames.
    assert_receive %Phoenix.Socket.Broadcast{payload: %{"note_id" => "other"}}, 200
    assert_receive %Phoenix.Socket.Broadcast{payload: %{"note_id" => "doomed"}}, 200
    refute_receive %Phoenix.Socket.Broadcast{payload: %{"note_id" => "doomed"}}, 100
  end
end
