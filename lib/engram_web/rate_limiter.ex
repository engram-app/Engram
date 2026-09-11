defmodule EngramWeb.RateLimiter do
  @moduledoc """
  Runtime-pluggable rate limiter. Call sites use `hit/3` and (in tests)
  `reset_buckets!/0`; this module routes to the configured concrete backend:

    * `:ets`             — `EngramWeb.RateLimiter.ETS` (default; per-node, no deps)
    * `:distributed_ets` — `EngramWeb.RateLimiter.DistributedETS` (cluster-shared
                           via PubSub broadcast; SaaS clustered-prod opt-in)

  Select via `config :engram, EngramWeb.RateLimiter, backend: :ets | :distributed_ets`.
  Because `use Hammer, backend:` is a compile-time choice, the two backends are
  separate modules and this façade dispatches at runtime — one release artifact
  serves both self-host (ETS) and SaaS (DistributedETS).

  ETS and DistributedETS are both in-memory and never fail in ways that require a
  fail-open guard; the prior Redis try/rescue path has been removed.
  """

  @type hit_result :: {:allow, non_neg_integer()} | {:deny, non_neg_integer()}

  @typedoc """
  Bounded limiter-purpose label for telemetry. A closed enum so the
  `engram_prom_ex_rate_limiter_hit_total` series can never carry the
  user_id / ip / request_path embedded in a bucket key.
  """
  @type purpose :: :preauth | :http | :api_rps | :voyage_embed | :cimd_fetch | :ai_search | :other

  @doc """
  Count a hit against `key` and emit `[:engram, :rate_limiter, :hit]` with the
  bounded `purpose` label and the allow/deny `result` (covers both backends).
  """
  @spec hit(String.t(), pos_integer(), non_neg_integer(), purpose()) :: hit_result()
  def hit(key, scale_ms, limit, purpose \\ :other) do
    result =
      case backend() do
        :distributed_ets -> EngramWeb.RateLimiter.DistributedETS.hit(key, scale_ms, limit)
        _ets -> EngramWeb.RateLimiter.ETS.hit(key, scale_ms, limit)
      end

    :telemetry.execute(
      [:engram, :rate_limiter, :hit],
      %{count: 1},
      %{purpose: purpose, result: elem(result, 0)}
    )

    result
  end

  @spec backend() :: :ets | :distributed_ets
  def backend do
    :engram |> Application.get_env(__MODULE__, []) |> Keyword.get(:backend, :ets)
  end

  if Mix.env() == :test do
    # Every scale a burst-then-deny test runs against is a multiple of 10s
    # (crdt edit/handshake budget 10s; HTTP, pre-auth, CIMD, telemetry 60s; AI
    # search 24h), so every window edge of every one of them is a 10s edge.
    @window_edge_ms 10_000
    # Longer than any burst takes, even under full-suite load (measured bursts
    # are 10-20ms), and short enough that the wait is rare: ~10% of calls, and
    # at most this long.
    @window_margin_ms 1_000

    @doc """
    Wipe every bucket and return at the start of a fresh window (test setup
    only). ETS-backed backends only.

    Wiping alone was half the promise. Hammer's `:fix_window` keys a count to
    `div(now, scale)`, so windows are epoch-aligned, and a burst that starts a
    few ms before an edge splits across two windows: the N+1th request lands
    in a new window as count 1 and is allowed. Every caller is a test about to
    burst and assert the last request is denied, so "fresh buckets" has to
    mean "with a window ahead to burst into". Measured: a 17ms CRDT burst
    across `07:22:10.000` (10s window) and an 11ms device-flow burst across
    `07:24:00.000` (60s window) both went red in one CI run.
    """
    def reset_buckets! do
      try do
        case backend() do
          :distributed_ets ->
            :ets.delete_all_objects(EngramWeb.RateLimiter.DistributedETS.Local)

          _ets ->
            :ets.delete_all_objects(EngramWeb.RateLimiter.ETS)
        end
      rescue
        # Safe no-op when the backend's ETS table isn't started (e.g. the
        # :distributed_ets supervisor isn't running under the current test config).
        ArgumentError -> :ok
      end

      case fresh_window_wait_ms(System.system_time(:millisecond)) do
        0 -> :ok
        wait -> Process.sleep(wait)
      end

      :ok
    end

    @doc false
    # Pure, so the edge arithmetic is testable without a clock. Same clock and
    # same `div/rem` shape Hammer's fix_window uses.
    def fresh_window_wait_ms(now_ms) do
      left = @window_edge_ms - rem(now_ms, @window_edge_ms)
      if left < @window_margin_ms, do: left + 1, else: 0
    end
  end
end
