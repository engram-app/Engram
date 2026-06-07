defmodule Engram.Telemetry.WebSocketPoller do
  @moduledoc """
  Periodic poller that emits the two WebSocket-shape gauges the
  `observability-coverage` milestone calls for:

    * `[:engram, :websocket, :count]` — live channel count, partitioned
      by `topic_prefix` (`"sync"`, `"user"`, `"presence"`, plus the
      synthetic `"total"`). Cheap split — one O(n) pass over the channel
      pid list.

    * `[:engram, :websocket, :socket_bytes]` — per-channel RAM footprint
      (`:erlang.process_info(pid, :memory)`). Emitted once per pid so the
      Telemetry.Metrics `distribution/2` collector can bucket the
      population. Captures the "users holding open huge subscriptions"
      failure mode.

  ## Why scan process labels, not Phoenix.Tracker

  Phoenix Channels server processes tag themselves with
  `Process.put(:"$process_label", {Phoenix.Channel, channel_mod, topic})`
  (see `Phoenix.Channel.Server.handle_info({Phoenix.Channel, ...}, _)`).
  This label is the cheapest correct way to enumerate channel pids
  without hooking the internals of `Phoenix.PubSub`'s registry — and it
  works whether or not the project uses `Phoenix.Presence` on every
  channel. Cost is ~one map+filter over `Process.list/0` every poll.

  ## Cardinality discipline

  Per the milestone scope: no per-user or per-vault labels. Only
  `topic_prefix` (bounded by the small set of channel definitions in
  `EngramWeb.UserSocket`) ever escapes as a Prometheus tag.
  """

  require Logger

  @count_event [:engram, :websocket, :count]
  @bytes_event [:engram, :websocket, :socket_bytes]

  @doc """
  Entry point invoked by `:telemetry_poller`. Public so the existing
  `Telemetry.Metrics` collector in `EngramWeb.Telemetry` can list it
  in `periodic_measurements/0`.
  """
  @spec measure() :: :ok
  def measure do
    pids = channel_pids()

    pids
    |> Enum.frequencies_by(&pid_topic_prefix/1)
    |> emit_counts()

    Enum.each(pids, &emit_socket_bytes/1)

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

  defp channel_pids do
    for pid <- Process.list(),
        info = safe_process_info(pid),
        info != nil,
        match?({Phoenix.Channel, _, _}, label_of(info)),
        do: pid
  end

  defp safe_process_info(pid) do
    # `Process.info/2` with `:dictionary` may return `nil` for processes
    # that died between Process.list/0 and the lookup — that race is
    # normal under load. Treat nil as "not a channel."
    case Process.info(pid, [:dictionary, :memory]) do
      nil -> nil
      info -> Map.new(info)
    end
  end

  defp label_of(%{dictionary: dict}) when is_list(dict) do
    Keyword.get(dict, :"$process_label")
  end

  defp label_of(_), do: nil

  defp pid_topic_prefix(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        case Keyword.get(dict, :"$process_label") do
          {Phoenix.Channel, _channel, topic} -> topic_prefix(topic)
          _ -> "unknown"
        end

      _ ->
        "unknown"
    end
  end

  defp emit_counts(counts_by_prefix) do
    total = counts_by_prefix |> Map.values() |> Enum.sum()

    Enum.each(counts_by_prefix, fn {prefix, count} ->
      :telemetry.execute(@count_event, %{count: count}, %{topic_prefix: prefix})
    end)

    :telemetry.execute(@count_event, %{count: total}, %{topic_prefix: "total"})
  end

  defp emit_socket_bytes(pid) do
    case Process.info(pid, [:dictionary, :memory]) do
      [{:dictionary, dict}, {:memory, bytes}] when is_integer(bytes) and bytes > 0 ->
        case Keyword.get(dict, :"$process_label") do
          {Phoenix.Channel, _channel, topic} ->
            :telemetry.execute(
              @bytes_event,
              %{bytes: bytes},
              %{topic_prefix: topic_prefix(topic)}
            )

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end
end
