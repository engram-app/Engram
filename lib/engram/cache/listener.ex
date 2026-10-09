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

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts) do
    Postgrex.SimpleConnection.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok), do: init(server: Engram.Cache.Server)

  def init(opts),
    do: {:ok, %{server: Keyword.fetch!(opts, :server), listening: false}}

  @impl true
  def handle_connect(state) do
    statements = Enum.map_join(Registry.channels(), "\n", &~s(LISTEN "#{&1}";))
    {:query, "DO $$ BEGIN #{statements} END $$", %{state | listening: true}}
  end

  @impl true
  def handle_disconnect(state), do: {:noreply, %{state | listening: false}}

  # The only query this connection runs is the LISTEN block above.
  @impl true
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

  @impl true
  def handle_call(_msg, from, state) do
    Postgrex.SimpleConnection.reply(from, :ok)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # The server may be down (restarting); its fresh tables are empty anyway.
  defp to_server(%{server: server}, msg) do
    case Process.whereis(server) do
      nil -> :ok
      pid -> send(pid, msg)
    end
  end
end
