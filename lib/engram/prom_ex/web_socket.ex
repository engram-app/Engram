defmodule Engram.PromEx.WebSocket do
  @moduledoc """
  PromEx plugin for WebSocket traffic: how many sockets are connected, how
  many frames move each way, and how many bytes.

  Events + metrics:

    * `[:engram, :websocket, :frame]` (from `EngramWeb.MeteredSerializer`) →
      `..._websocket_frames_total` and `..._websocket_frame_bytes_total`, tags
      `[:direction, :kind, :topic_prefix]`. `direction` is `:in | :out`; `kind`
      is `:push | :reply | :broadcast`. Broadcast frames count per delivering
      socket, not per broadcast.
    * `[:engram, :websocket, :connections]` (polled) →
      `..._websocket_connections`, tag `[:socket]`. One per transport process,
      i.e. per client connection.
    * `[:engram, :websocket, :count]` (polled) → `..._websocket_channels`, tag
      `[:topic_prefix]`. Joined channels; one connection hosts several.
    * `[:engram, :websocket, :socket_bytes]` (polled) →
      `..._websocket_channel_memory_bytes`, per-channel-process RAM.

  The poll is `Engram.Telemetry.WebSocketPoller.measure/0`, an O(processes)
  scan, hence the 30s default.

  Cardinality contract: only the bounded tags above. NEVER topic, event,
  user_id, or vault_id.
  """

  use PromEx.Plugin

  @impl true
  def event_metrics(opts) do
    metric_prefix = PromEx.metric_prefix(Keyword.fetch!(opts, :otp_app), :websocket)
    tags = [:direction, :kind, :topic_prefix]

    Event.build(:engram_websocket_event_metrics, [
      sum(metric_prefix ++ [:frames, :total],
        event_name: [:engram, :websocket, :frame],
        measurement: :count,
        description:
          "WebSocket frames by direction, kind (push/reply/broadcast) and topic prefix.",
        tags: tags
      ),
      sum(metric_prefix ++ [:frame_bytes, :total],
        event_name: [:engram, :websocket, :frame],
        measurement: :bytes,
        description: "WebSocket wire bytes by direction, kind and topic prefix.",
        tags: tags
      )
    ])
  end

  @impl true
  def polling_metrics(opts) do
    metric_prefix = PromEx.metric_prefix(Keyword.fetch!(opts, :otp_app), :websocket)
    poll_rate = Keyword.get(opts, :websocket_poll_rate, 30_000)

    Polling.build(
      :engram_websocket_polling_metrics,
      poll_rate,
      {Engram.Telemetry.WebSocketPoller, :measure, []},
      [
        last_value(metric_prefix ++ [:connections],
          event_name: [:engram, :websocket, :connections],
          measurement: :count,
          description: "Live WebSocket connections (transport processes) by socket.",
          tags: [:socket]
        ),
        last_value(metric_prefix ++ [:channels],
          event_name: [:engram, :websocket, :count],
          measurement: :count,
          description: "Live joined channels by topic prefix, plus \"total\".",
          tags: [:topic_prefix]
        ),
        distribution(metric_prefix ++ [:channel_memory, :bytes],
          event_name: [:engram, :websocket, :socket_bytes],
          measurement: :bytes,
          description:
            "Per-channel-process RAM. A high bucket is a tenant pinning a fat subscription.",
          tags: [:topic_prefix],
          unit: :byte,
          reporter_options: [
            buckets: [16_384, 65_536, 262_144, 1_048_576, 4_194_304, 16_777_216, 67_108_864]
          ]
        )
      ]
    )
  end
end
