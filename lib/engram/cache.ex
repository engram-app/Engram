defmodule Engram.Cache do
  @moduledoc """
  Runtime-pluggable cache store shared by the per-user caches
  (`Engram.UsageMeters.ActivityCache`, `Engram.Onboarding.TermsCache`).

  Backend selected via `config :engram, Engram.Cache, backend: :ets | :redis`:

    * `:ets`   — each cache owns a per-node ETS table (default; self-host, and
      any deploy without `REDIS_URL`).
    * `:redis` — a cluster-shared Redis/Valkey store, so a write on one node is
      visible to all (SaaS opt-in, gated on `REDIS_URL` in `runtime.exs`).

  This module owns only the Redis path; the ETS path lives in each cache because
  the key/value shapes differ. Redis ops **fail open**: any error returns a miss
  (`redis_get/2`) or is swallowed (`redis_set/4`) after emitting
  `[:engram, :cache, :backend_error]` telemetry, so a store outage degrades to
  the authoritative DB read-through instead of failing the request. The event is
  tagged with `cache` (`:activity | :terms`) and `op` (`:get | :set`) so a
  degraded store is attributable per cache/op in CloudWatch — the metric is
  registered in `EngramWeb.Telemetry` (registration is what makes the "alert"
  half of fail-open+alert actually reach a reporter).
  """

  @type cache :: :activity | :terms
  @type op :: :get | :set
  @type get_result :: {:ok, binary()} | :miss

  @spec backend() :: :ets | :redis
  def backend do
    :engram
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:backend, :ets)
  end

  @doc """
  Fetch a key from the shared store. Returns `{:ok, value}` on a hit, `:miss`
  for an absent key, and — on any store error — `:miss` after emitting
  backend-error telemetry (fail-open). `cache` labels the calling cache for
  observability.
  """
  @spec redis_get(cache(), String.t()) :: get_result()
  def redis_get(cache, key) do
    case impl().command(["GET", key]) do
      {:ok, nil} -> :miss
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:error, reason} -> degrade(cache, :get, reason)
    end
  rescue
    error -> degrade(cache, :get, error)
  catch
    :exit, reason -> degrade(cache, :get, reason)
  end

  @doc """
  Write a key with a TTL (seconds). Always returns `:ok`; store errors are
  swallowed after emitting telemetry (fail-open — a failed cache write just
  means the next read re-derives from the DB).
  """
  @spec redis_set(cache(), String.t(), String.t(), pos_integer()) :: :ok
  def redis_set(cache, key, value, ttl_seconds) do
    case impl().command(["SET", key, value, "EX", Integer.to_string(ttl_seconds)]) do
      {:ok, _} -> :ok
      {:error, reason} -> emit_backend_error(cache, :set, reason)
    end
  rescue
    error -> emit_backend_error(cache, :set, error)
  catch
    :exit, reason -> emit_backend_error(cache, :set, reason)
  end

  @doc """
  Emit a cache backend-error event directly. For callers that detect a store
  problem the get/set wrappers can't see — e.g. a value that decodes wrong
  (corrupt/foreign write) — so it's distinguishable from a normal `:miss`.
  """
  @spec report_backend_error(cache(), op(), term()) :: :ok
  def report_backend_error(cache, op, reason), do: emit_backend_error(cache, op, reason)

  # Overridable so tests can inject a fake/raising command impl; prod uses the
  # real Redix connection. Reads the same Engram.Cache config keyword list.
  defp impl do
    :engram
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:redis_impl, Engram.Cache.Redix)
  end

  defp degrade(cache, op, reason) do
    emit_backend_error(cache, op, reason)
    :miss
  end

  defp emit_backend_error(cache, op, reason) do
    :telemetry.execute(
      [:engram, :cache, :backend_error],
      %{count: 1},
      # Bounded, log-safe reason — see Engram.Telemetry.error_kind/1 (the raw
      # term can carry the REDIS_URL password and telemetry skips redaction).
      %{cache: cache, op: op, reason: Engram.Telemetry.error_kind(reason)}
    )

    :ok
  end
end
