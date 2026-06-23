defmodule EngramWeb.RateLimiter.DistributedETS do
  @moduledoc """
  Cluster-aware rate limiter: a per-node Hammer ETS counter plus a
  `Phoenix.PubSub` broadcast (Hammer v7's official distributed-ETS pattern,
  as run by hex.pm).

  A local `hit/3,4` broadcasts `{:inc, key, scale, increment}` to peers via
  `broadcast_from` — which excludes THIS node, so it never double-counts its
  own hits — then checks + counts locally via `Local.hit`. The `Listener`
  applies remote `:inc` messages via `Local.inc/3` (count-only, no re-broadcast)
  so there is no echo loop.

  Eventually consistent: overshoot ≈ rate × intra-cluster propagation (~ms),
  new nodes start empty, netsplits drop in-flight increments — every failure
  biases permissive, which is correct for abuse/burst limiters. PubSub
  membership is PID-based, so ephemeral node names (Fargate rolling deploys)
  don't matter. Single node → `broadcast_from` reaches no subscribers (no-op).

  Self-host / single-node uses the plain `EngramWeb.RateLimiter.ETS` backend
  instead (no broadcast). Same `hit/3` contract as every backend.
  """
  @pubsub Engram.PubSub
  @topic "rate_limiter:sync"

  defmodule Local do
    @moduledoc false
    use Hammer, backend: :ets
  end

  defmodule Listener do
    @moduledoc false
    use GenServer

    alias EngramWeb.RateLimiter.DistributedETS.Local

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts) do
      pubsub = Keyword.fetch!(opts, :pubsub)
      topic = Keyword.fetch!(opts, :topic)
      :ok = Phoenix.PubSub.subscribe(pubsub, topic)
      {:ok, %{}}
    end

    # Remote increment → apply to the local ETS counter WITHOUT re-broadcasting.
    # The `:applied` / `:dropped` telemetry is the cross-node sync signal: on a
    # rolling deploy, `rate(...remote_inc_total{result="applied"}[1m])` ramping
    # from a new task's boot shows it warming from peers (no state handoff exists).
    @impl true
    def handle_info({:inc, key, scale, increment}, state) do
      _ = Local.inc(key, scale, increment)

      :telemetry.execute(
        [:engram, :rate_limiter, :remote_inc],
        %{count: 1},
        %{result: :applied}
      )

      {:noreply, state}
    rescue
      error ->
        require Logger

        Logger.warning(
          "rate limiter dropped a remote increment",
          Engram.Logger.Metadata.with_category(:warning, :auth,
            error_kind: Engram.Telemetry.error_kind(error)
          )
        )

        :telemetry.execute(
          [:engram, :rate_limiter, :remote_inc],
          %{count: 1},
          %{result: :dropped}
        )

        {:noreply, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}
  end

  @spec hit(String.t(), pos_integer(), non_neg_integer(), non_neg_integer()) ::
          {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def hit(key, scale, limit, increment \\ 1) do
    _ = broadcast({:inc, key, scale, increment})
    Local.hit(key, scale, limit, increment)
  end

  # broadcast_from the Listener pid → PubSub skips delivery back to this node's
  # Listener (which already counted via Local.hit). On a single node this
  # delivers to zero subscribers — a clean no-op.
  defp broadcast(message) do
    case Process.whereis(Listener) do
      nil -> :ok
      pid -> Phoenix.PubSub.broadcast_from(@pubsub, pid, @topic, message)
    end
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
  end

  def start_link(opts) do
    children = [{Local, opts}, {Listener, pubsub: @pubsub, topic: @topic}]
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Supervisor)
  end
end
