defmodule EngramWeb.RateLimiter do
  @moduledoc """
  Runtime-pluggable rate limiter. Call sites use `hit/3` and (in tests)
  `reset_buckets!/0`; this module routes to the configured concrete backend:

    * `:ets`   — `EngramWeb.RateLimiter.ETS` (default; per-node, single-node correct)
    * `:redis` — `EngramWeb.RateLimiter.Redis` (cluster-shared; SaaS opt-in)

  Select via `config :engram, EngramWeb.RateLimiter, backend: :ets | :redis`.
  Because `use Hammer, backend:` is a compile-time choice, the two backends are
  separate modules and this façade dispatches at runtime — one release artifact
  serves both self-host (ETS) and SaaS (Redis).

  Failure policy: **fail-open + alert.** If the Redis backend is unreachable,
  `hit/3` allows the request (`{:allow, 0}`) and emits
  `[:engram, :rate_limiter, :backend_error]` telemetry so the degraded limiter
  is visible in CloudWatch. Availability beats abuse-protection during a store
  outage. ETS never fails this way, so the guard only wraps the Redis path.
  """

  @type hit_result :: {:allow, non_neg_integer()} | {:deny, non_neg_integer()}

  @spec hit(String.t(), pos_integer(), non_neg_integer()) :: hit_result()
  def hit(key, scale_ms, limit) do
    case backend() do
      :redis ->
        try do
          EngramWeb.RateLimiter.Redis.hit(key, scale_ms, limit)
        rescue
          error -> fail_open(error)
        catch
          :exit, reason -> fail_open(reason)
        end

      _ets ->
        EngramWeb.RateLimiter.ETS.hit(key, scale_ms, limit)
    end
  end

  @spec backend() :: :ets | :redis
  def backend do
    :engram
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:backend, :ets)
  end

  defp fail_open(reason) do
    :telemetry.execute(
      [:engram, :rate_limiter, :backend_error],
      %{count: 1},
      %{backend: :redis, reason: inspect(reason)}
    )

    {:allow, 0}
  end

  if Mix.env() == :test do
    @doc "Wipe every bucket (test setup only). Delegates to the ETS table."
    def reset_buckets! do
      :ets.delete_all_objects(EngramWeb.RateLimiter.ETS)
    end
  end
end
