defmodule Engram.Telemetry.WebSocketPoller do
  @moduledoc """
  Periodic poller (driven by `Engram.PromEx.WebSocket`) for the WebSocket-shape
  gauges:

    * `[:engram, :websocket, :connections]` — live socket connections (one
      transport process each), by `socket` (`"user"`, `"device"`, `"other"`).

    * `[:engram, :websocket, :count]` — live channel count, partitioned
      by `topic_prefix` (`"sync"`, `"crdt"`, `"user"`, `"device"`, plus the
      synthetic `"total"`). One socket hosts several channels, so this is
      not a connection count.

    * `[:engram, :websocket, :socket_bytes]` — per-channel RAM footprint
      (`:erlang.process_info(pid, :memory)`). Emitted once per pid so the
      Telemetry.Metrics `distribution/2` collector can bucket the
      population. Captures the "users holding open huge subscriptions"
      failure mode.

  ## Why scan process labels, not Phoenix.Tracker

  Phoenix Channels server processes tag themselves with
  `Process.put(:"$process_label", {Phoenix.Channel, channel_mod, topic})`
  (see `Phoenix.Channel.Server.handle_info({Phoenix.Channel, ...}, _)`), and
  socket transport processes with `{Phoenix.Socket, handler, id}` (see
  `Phoenix.Socket.__init__/1`).
  This label is the cheapest correct way to enumerate channel pids
  without hooking the internals of `Phoenix.PubSub`'s registry — and it
  works whether or not the project uses `Phoenix.Presence` on every
  channel. Cost is ~one map+filter over `Process.list/0` every poll.

  ## Cardinality discipline

  Per the milestone scope: no per-user or per-vault labels. Only
  `topic_prefix` (bounded by the small set of channel definitions in
  `EngramWeb.UserSocket`) and `socket` ever escape as Prometheus tags.

  Known prefixes and sockets are always emitted, as 0 when idle. These feed
  `last_value` gauges, which serve their last sample forever: omitting an
  empty series would freeze its old count.
  """

  @count_event [:engram, :websocket, :count]
  @connections_event [:engram, :websocket, :connections]
  @bytes_event [:engram, :websocket, :socket_bytes]

  @channel_prefixes ~w(sync crdt user device)
  @sockets %{EngramWeb.UserSocket => "user", EngramWeb.DeviceSocket => "device"}

  @doc """
  Entry point invoked by the `Engram.PromEx.WebSocket` polling group.
  """
  @spec measure() :: :ok
  def measure do
    labelled =
      for pid <- Process.list(),
          label = :proc_lib.get_label(pid),
          label != :undefined,
          do: {pid, label}

    channels = for {pid, {Phoenix.Channel, _, topic}} <- labelled, do: {pid, topic_prefix(topic)}
    sockets = for {_pid, {Phoenix.Socket, handler, _}} <- labelled, do: socket_name(handler)

    channels |> Enum.frequencies_by(&elem(&1, 1)) |> emit_counts()
    sockets |> Enum.frequencies() |> emit_connections()
    Enum.each(channels, fn {pid, prefix} -> emit_socket_bytes(pid, prefix) end)

    :ok
  end

  @doc """
  Splits a Phoenix topic string on the first `:` and returns the prefix.

  Used for the metric tag and as a label generator for unit tests.
  Bounded cardinality by the channel macro list in
  `EngramWeb.UserSocket`.
  """
  @spec topic_prefix(term()) :: String.t()
  def topic_prefix(topic) when is_binary(topic) do
    case :binary.split(topic, ":") do
      [prefix, _rest] -> prefix
      [whole] -> whole
    end
  end

  def topic_prefix(_), do: "unknown"

  # ----- internals -----

  defp socket_name(handler), do: Map.get(@sockets, handler, "other")

  defp emit_counts(counts_by_prefix) do
    total = counts_by_prefix |> Map.values() |> Enum.sum()

    @channel_prefixes
    |> Map.new(&{&1, 0})
    |> Map.merge(counts_by_prefix)
    |> Enum.each(fn {prefix, count} ->
      :telemetry.execute(@count_event, %{count: count}, %{topic_prefix: prefix})
    end)

    :telemetry.execute(@count_event, %{count: total}, %{topic_prefix: "total"})
  end

  defp emit_connections(counts_by_socket) do
    @sockets
    |> Map.values()
    |> Map.new(&{&1, 0})
    |> Map.merge(counts_by_socket)
    |> Enum.each(fn {socket, count} ->
      :telemetry.execute(@connections_event, %{count: count}, %{socket: socket})
    end)
  end

  defp emit_socket_bytes(pid, prefix) do
    # nil when the channel exited after the scan; that race is normal.
    case Process.info(pid, :memory) do
      {:memory, bytes} when bytes > 0 ->
        :telemetry.execute(@bytes_event, %{bytes: bytes}, %{topic_prefix: prefix})

      _ ->
        :ok
    end
  end
end
