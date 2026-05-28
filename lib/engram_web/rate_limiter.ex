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
  is visible in CloudWatch. The emitted `:reason` metadata is a bounded
  classifier atom (never the raw term, which can carry the REDIS_URL password).
  Availability beats abuse-protection during a store outage. ETS never fails
  this way, so the guard only wraps the Redis path.
  """

  @type hit_result :: {:allow, non_neg_integer()} | {:deny, non_neg_integer()}

  @spec hit(String.t(), pos_integer(), non_neg_integer()) :: hit_result()
  def hit(key, scale_ms, limit) do
    case backend() do
      :redis ->
        try do
          redis_impl().hit(key, scale_ms, limit)
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

  # Overridable so tests can inject a backend that raises/exits; prod uses the
  # compiled Redis limiter. Reads the same RateLimiter config keyword list.
  defp redis_impl do
    :engram
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:redis_impl, EngramWeb.RateLimiter.Redis)
  end

  defp fail_open(reason) do
    :telemetry.execute(
      [:engram, :rate_limiter, :backend_error],
      %{count: 1},
      %{backend: :redis, reason: error_kind(reason)}
    )

    {:allow, 0}
  end

  # Map an arbitrary failure to a bounded, log-safe atom. NEVER forward the raw
  # reason: a Redix/connection error term can carry the REDIS_URL (incl. its
  # password), and telemetry metadata does not pass through the Logger redaction
  # filter. Matches the convention in Engram.Telemetry.ObanDiscardHandler.
  defp error_kind(reason) when is_atom(reason), do: reason
  defp error_kind({kind, _}) when is_atom(kind), do: kind
  defp error_kind(%{__exception__: true} = e), do: e.__struct__
  defp error_kind(_), do: :other

  if Mix.env() == :test do
    @doc "Wipe every bucket (test setup only). ETS backend only."
    def reset_buckets! do
      if backend() == :redis do
        raise "reset_buckets!/0 only supports the ETS backend; got :redis"
      end

      :ets.delete_all_objects(EngramWeb.RateLimiter.ETS)
    end
  end
end
