defmodule EngramWeb.MeteredSerializer do
  @moduledoc """
  The stock V2 JSON serializer, plus one `[:engram, :websocket, :frame]` event
  per frame. Every channel frame crosses the serializer in one direction or the
  other, so this is the single place message rate and wire bytes can be
  measured without touching each channel.

  Measurements `%{count: n, bytes: b}`; metadata `%{direction, kind, topic_prefix}`:

    * `decode!/2` — `direction: :in`, `kind: :push`, one per client frame.
    * `encode!/1` — `direction: :out`, `kind: :push | :reply`. Called once per
      socket, so `count: 1`.
    * `fastlane!/1` — `direction: :out`, `kind: :broadcast`. Phoenix encodes a
      broadcast ONCE per node and sends the same binary to every local
      subscriber (`Phoenix.Channel.Server.dispatch/3`), so counting calls would
      count broadcasts, not deliveries. `count` is the number of local
      subscribers that receive this encoding instead, and `bytes` is that many
      copies. Subscribers that intercept the event get the raw `Broadcast`,
      push it themselves, and are counted by `encode!/1`.

  `topic_prefix` is bounded to the routed prefixes plus `"phoenix"`
  (heartbeats); anything else is `"other"`. Join replies echo whatever topic
  the client asked for, so the raw prefix would let a client mint label values.
  """

  @behaviour Phoenix.Socket.Serializer

  alias Phoenix.Socket.{Broadcast, Message}
  alias Phoenix.Socket.V2.JSONSerializer, as: Inner

  @event [:engram, :websocket, :frame]
  @pubsub Engram.PubSub
  @known_prefixes ~w(sync crdt user device phoenix)

  @impl true
  def fastlane!(%Broadcast{} = msg) do
    encoded = Inner.fastlane!(msg)
    emit(:out, :broadcast, msg.topic, frame_bytes(encoded), fastlane_recipients(msg))
    encoded
  end

  @impl true
  def encode!(msg) do
    encoded = Inner.encode!(msg)
    kind = if match?(%Message{}, msg), do: :push, else: :reply
    emit(:out, kind, msg.topic, frame_bytes(encoded), 1)
    encoded
  end

  @impl true
  def decode!(raw, opts) do
    msg = Inner.decode!(raw, opts)
    emit(:in, :push, msg.topic, IO.iodata_length(raw), 1)
    msg
  end

  @doc false
  @spec known_prefixes() :: [String.t()]
  def known_prefixes, do: @known_prefixes

  defp emit(direction, kind, topic, bytes, count) do
    :telemetry.execute(@event, %{count: count, bytes: bytes * count}, %{
      direction: direction,
      kind: kind,
      topic_prefix: bounded_prefix(topic)
    })
  end

  defp bounded_prefix(topic) when is_binary(topic) do
    prefix = topic |> :binary.split(":") |> hd()
    if prefix in @known_prefixes, do: prefix, else: "other"
  end

  defp bounded_prefix(_), do: "other"

  defp frame_bytes({:socket_push, _opcode, data}), do: IO.iodata_length(data)

  # ponytail: O(local subscribers) per broadcast, the same walk dispatch/3 does.
  # Overcounts by one on broadcast_from/4 (the sender is skipped by dispatch but
  # not visible here).
  defp fastlane_recipients(%Broadcast{topic: topic, event: event}) do
    @pubsub
    |> Registry.select([{{topic, :_, {:fastlane, :_, __MODULE__, :"$1"}}, [], [:"$1"]}])
    |> Enum.count(&(event not in &1))
  end
end
