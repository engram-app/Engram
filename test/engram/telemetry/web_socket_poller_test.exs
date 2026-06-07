defmodule Engram.Telemetry.WebSocketPollerTest do
  @moduledoc """
  Pins the WebSocket gauge poller wiring.

  The poller is the only hook between live channel processes and the
  Prometheus reporter — without these assertions a future refactor can
  silently regress us back to "we have no idea how many sockets are
  connected" (the failure mode the obs-coverage milestone calls out).
  """

  use ExUnit.Case, async: false

  alias Engram.Telemetry.WebSocketPoller

  setup do
    handler_id = {__MODULE__, :rand.uniform(1_000_000)}
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:engram, :websocket, :count],
          [:engram, :websocket, :socket_bytes]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  describe "measure/0 — count gauge" do
    test "emits engram.websocket.count once per topic_prefix" do
      # Spawn two fake channel processes with sync:* labels and one user:*.
      spawn_channel_proc({Phoenix.Channel, EngramWeb.SyncChannel, "sync:1:a"})
      spawn_channel_proc({Phoenix.Channel, EngramWeb.SyncChannel, "sync:2:b"})
      spawn_channel_proc({Phoenix.Channel, EngramWeb.UserChannel, "user:42"})

      WebSocketPoller.measure()

      events = collect_count_events()

      # One event per discovered topic_prefix plus the synthetic :total.
      prefixes = Map.new(events, fn {_, m, meta} -> {meta.topic_prefix, m.count} end)

      assert prefixes["sync"] >= 2
      assert prefixes["user"] >= 1
      assert prefixes["total"] >= prefixes["sync"] + prefixes["user"]
    end

    test "topic_prefix tag is always a string and bounded in cardinality" do
      spawn_channel_proc({Phoenix.Channel, EngramWeb.SyncChannel, "sync:9:z"})
      WebSocketPoller.measure()

      for {_, _, meta} <- collect_count_events() do
        assert is_binary(meta.topic_prefix),
               "topic_prefix must be a string (Prometheus tag), got: #{inspect(meta.topic_prefix)}"
      end
    end
  end

  describe "measure/0 — per-socket RAM distribution" do
    test "emits one engram.websocket.socket_bytes event per discovered channel" do
      spawn_channel_proc({Phoenix.Channel, EngramWeb.SyncChannel, "sync:1:a"})
      spawn_channel_proc({Phoenix.Channel, EngramWeb.SyncChannel, "sync:2:b"})

      WebSocketPoller.measure()

      events =
        Stream.repeatedly(fn ->
          receive do
            {:telemetry, [:engram, :websocket, :socket_bytes], m, meta} -> {m, meta}
          after
            100 -> nil
          end
        end)
        |> Enum.take_while(&(&1 != nil))

      assert length(events) >= 2,
             "expected one socket_bytes event per channel pid, got #{length(events)}"

      for {m, meta} <- events do
        assert is_integer(m.bytes) and m.bytes > 0,
               "bytes measurement must be a positive integer"

        assert is_binary(meta.topic_prefix),
               "topic_prefix metadata must be a string"
      end
    end

    test "does NOT include per-user or per-vault labels (cardinality guard)" do
      spawn_channel_proc({Phoenix.Channel, EngramWeb.SyncChannel, "sync:1:vault-aaa"})
      WebSocketPoller.measure()

      events =
        Stream.repeatedly(fn ->
          receive do
            {:telemetry, [:engram, :websocket, :socket_bytes], _, meta} -> meta
          after
            100 -> nil
          end
        end)
        |> Enum.take_while(&(&1 != nil))

      for meta <- events do
        refute Map.has_key?(meta, :user_id), "user_id label leaks tenant cardinality"
        refute Map.has_key?(meta, :vault_id), "vault_id label leaks tenant cardinality"
        refute Map.has_key?(meta, :topic), "raw topic label leaks tenant cardinality"
      end
    end
  end

  describe "topic_prefix/1" do
    test "splits a Phoenix-style topic on the first colon" do
      assert "sync" == WebSocketPoller.topic_prefix("sync:1:vault-a")
      assert "user" == WebSocketPoller.topic_prefix("user:42")
    end

    test "returns the whole topic when no colon is present" do
      assert "lobby" == WebSocketPoller.topic_prefix("lobby")
    end

    test "returns 'unknown' for nil / non-binary topics" do
      assert "unknown" == WebSocketPoller.topic_prefix(nil)
      assert "unknown" == WebSocketPoller.topic_prefix(:not_a_string)
    end
  end

  # ----- helpers -----

  defp spawn_channel_proc(label) do
    test_pid = self()

    pid =
      spawn(fn ->
        Process.put(:"$process_label", label)
        send(test_pid, {:ready, self()})

        receive do
          :stop -> :ok
        after
          5_000 -> :ok
        end
      end)

    receive do
      {:ready, ^pid} -> :ok
    after
      1_000 -> flunk("fake channel proc did not start")
    end

    # No on_exit/1 here — it only works in setup blocks. The 5_000ms
    # receive timeout in the spawned proc bounds cleanup.
    pid
  end

  defp collect_count_events do
    Stream.repeatedly(fn ->
      receive do
        {:telemetry, [:engram, :websocket, :count], _, _} = e -> e
      after
        100 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
    |> Enum.map(fn {:telemetry, e, m, meta} -> {e, m, meta} end)
  end
end
