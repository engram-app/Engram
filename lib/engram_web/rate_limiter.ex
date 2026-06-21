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

  @spec hit(String.t(), pos_integer(), non_neg_integer()) :: hit_result()
  def hit(key, scale_ms, limit) do
    case backend() do
      :distributed_ets -> EngramWeb.RateLimiter.DistributedETS.hit(key, scale_ms, limit)
      _ets -> EngramWeb.RateLimiter.ETS.hit(key, scale_ms, limit)
    end
  end

  @spec backend() :: :ets | :distributed_ets
  def backend do
    :engram |> Application.get_env(__MODULE__, []) |> Keyword.get(:backend, :ets)
  end

  if Mix.env() == :test do
    @doc "Wipe every bucket (test setup only). ETS-backed backends only."
    def reset_buckets! do
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
  end
end
