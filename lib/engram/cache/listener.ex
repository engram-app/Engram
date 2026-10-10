defmodule Engram.Cache.Listener do
  @moduledoc """
  The node's LISTEN connection for `Engram.Cache` eviction triggers.

  A `Postgrex.SimpleConnection` rather than `Postgrex.Notifications` because
  the cache must know when the connection (re)connects: Postgres drops every
  NOTIFY sent while it was down, so a revoked key or a suspension written on
  another node during the gap would otherwise be served until its TTL. Once
  the LISTEN is back in place it tells `Engram.Cache.Server`, which clears
  every NOTIFY-evicted cache.

  Notifications are forwarded to the server as
  `{:notification, self(), nil, channel, payload}`.
  """
  @behaviour Postgrex.SimpleConnection

  alias Engram.Cache.Registry

  require Logger

  @retry_ms 5_000

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts) do
    Postgrex.SimpleConnection.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok), do: init(server: Engram.Cache.Server)

  def init(opts) do
    {:ok,
     %{
       server: Keyword.fetch!(opts, :server),
       retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
       listening: false,
       connected: false
     }}
  end

  @impl true
  def handle_connect(state),
    do: {:query, listen_sql(), %{state | listening: true, connected: true}}

  defp listen_sql do
    statements = Enum.map_join(Registry.channels(), "\n", &~s(LISTEN "#{&1}";))
    "DO $$ BEGIN #{statements} END $$"
  end

  @impl true
  def handle_disconnect(state), do: {:noreply, %{state | listening: false, connected: false}}

  # The only query this connection runs is the LISTEN block above. A failure
  # is NOT reported as connected: the node runs TTL-only until a retry lands.
  @impl true
  def handle_result(%Postgrex.Error{} = error, state) do
    Logger.warning(
      "cache: failed to LISTEN (#{Exception.message(error)}); TTL-only eviction, retrying",
      Engram.Logger.Metadata.with_category(:warning, :data, [])
    )

    Process.send_after(self(), :relisten, state.retry_ms)
    {:noreply, %{state | listening: false}}
  end

  def handle_result(_result, %{listening: true} = state) do
    to_server(state, :pg_listen_connected)
    {:noreply, state}
  end

  def handle_result(_result, state), do: {:noreply, state}

  @impl true
  def notify(channel, payload, state) do
    to_server(state, {:notification, self(), nil, channel, payload})
    :ok
  end

  # Not a Postgrex.Notifications: LISTEN is owned here, not requested by callers.
  @impl true
  def handle_call(_msg, from, state) do
    Postgrex.SimpleConnection.reply(from, {:error, :unsupported})
    {:noreply, state}
  end

  @impl true
  # A retry that fires while disconnected is dropped: the reconnect's
  # handle_connect issues the LISTEN itself.
  def handle_info(:relisten, %{connected: true} = state),
    do: {:query, listen_sql(), %{state | listening: true}}

  def handle_info(_msg, state), do: {:noreply, state}

  # The server may be down (restarting); its fresh tables are empty anyway.
  defp to_server(%{server: server}, msg) do
    case Process.whereis(server) do
      nil -> :ok
      pid -> send(pid, msg)
    end
  end
end
