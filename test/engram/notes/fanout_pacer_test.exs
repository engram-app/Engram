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
end
