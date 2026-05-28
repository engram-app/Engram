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
  (`redis_get/1`) or is swallowed (`redis_set/3`) after emitting
  `[:engram, :cache, :backend_error]` telemetry, so a store outage degrades to
  the authoritative DB read-through instead of failing the request.
  """

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
  backend-error telemetry (fail-open).
  """
  @spec redis_get(String.t()) :: get_result()
  def redis_get(key) do
    case impl().command(["GET", key]) do
      {:ok, nil} -> :miss
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:error, reason} -> degrade(reason)
    end
  rescue
    error -> degrade(error)
  catch
    :exit, reason -> degrade(reason)
  end

  @doc """
  Write a key with a TTL (seconds). Always returns `:ok`; store errors are
  swallowed after emitting telemetry (fail-open — a failed cache write just
  means the next read re-derives from the DB).
  """
  @spec redis_set(String.t(), String.t(), pos_integer()) :: :ok
  def redis_set(key, value, ttl_seconds) do
    case impl().command(["SET", key, value, "EX", Integer.to_string(ttl_seconds)]) do
      {:ok, _} -> :ok
      {:error, reason} -> emit_backend_error(reason)
    end
  rescue
    error -> emit_backend_error(error)
  catch
    :exit, reason -> emit_backend_error(reason)
  end

  # Overridable so tests can inject a fake/raising command impl; prod uses the
  # real Redix connection. Reads the same Engram.Cache config keyword list.
  defp impl do
    :engram
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:redis_impl, Engram.Cache.Redix)
  end

  defp degrade(reason) do
    emit_backend_error(reason)
    :miss
  end

  defp emit_backend_error(reason) do
    :telemetry.execute(
      [:engram, :cache, :backend_error],
      %{count: 1},
      %{reason: error_kind(reason)}
    )

    :ok
  end

  # Map an arbitrary failure to a bounded, log-safe atom. NEVER forward the raw
  # reason: a Redix/connection error term can carry the REDIS_URL (incl. its
  # password), and telemetry metadata does not pass through the Logger redaction
  # filter. Mirrors EngramWeb.RateLimiter.error_kind/1.
  defp error_kind(reason) when is_atom(reason), do: reason
  defp error_kind({kind, _}) when is_atom(kind), do: kind
  defp error_kind(%{__exception__: true} = e), do: e.__struct__
  defp error_kind(_), do: :other
end
