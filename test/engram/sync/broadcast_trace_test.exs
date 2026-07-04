defmodule Engram.Sync.BroadcastTraceTest do
  @moduledoc """
  Emit-side breadcrumb for the `note_changed` broadcast path.

  The broadcast is fastlaned PubSub → socket (the sync channel has no
  `handle_out`), so the ONLY server-side observable that a broadcast fired is
  this emit log. It lets a CI flake capture line the emit (topic = sync:user:vault
  + note_id) up against the receiver's already-traced `sync join`/`sync leave` to
  bisect a server-emit gap from a client-side drop (e2e-clerk test_78 stall).

  Privacy: only UUIDs are logged (topic + note_id). Never the note path or content.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Engram.Sync.Broadcast

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok
  end

  test "emit logs a breadcrumb with topic, event, and note_id for note_changed" do
    log =
      capture_log(fn ->
        Broadcast.emit("sync:user-1:vault-1", "note_changed", %{
          "event_type" => "upsert",
          "id" => "note-abc"
        })
      end)

    assert log =~ "sync broadcast emit"
    assert log =~ "sync:user-1:vault-1"
    assert log =~ "note_changed"
    assert log =~ "note-abc"
  end

  test "a deferred flush also logs the breadcrumb at actual emission (on commit)" do
    log =
      capture_log(fn ->
        Broadcast.deferred(fn ->
          Broadcast.emit("sync:u:v", "note_changed", %{"id" => "deferred-note"})
          # Still buffered — nothing emitted (or logged) yet inside the fun.
          {:ok, :done}
        end)
      end)

    assert log =~ "sync broadcast emit"
    assert log =~ "deferred-note"
  end

  test "a discarded (rolled-back) deferral logs NO emit breadcrumb" do
    log =
      capture_log(fn ->
        Broadcast.deferred(fn ->
          Broadcast.emit("sync:u:v", "note_changed", %{"id" => "rolled-back"})
          {:error, :conflict}
        end)
      end)

    refute log =~ "rolled-back"
  end
end
