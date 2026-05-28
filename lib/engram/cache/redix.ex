defmodule Engram.Cache.Redix do
  @moduledoc """
  Real Redix connection backing `Engram.Cache` in `:redis` mode. Owns a single
  named connection (`:engram_cache_redix`) separate from the rate limiter's
  Hammer-managed connection — same `REDIS_URL`, distinct logical pool.

  Started from `Engram.Application` only when the cache backend is `:redis`.
  `sync_connect: false` so boot never blocks on Redis reachability; the façade
  fails open while the connection (re)establishes. The 250ms command timeout
  keeps fail-open fast under a partition (Redix default is `:infinity`).
  """

  @conn :engram_cache_redix
  @timeout 250

  def child_spec(opts) do
    url = Keyword.fetch!(opts, :url)

    %{
      id: __MODULE__,
      start: {Redix, :start_link, [url, [name: @conn, sync_connect: false]]}
    }
  end

  @spec command([String.t()]) :: {:ok, term()} | {:error, term()}
  def command(args), do: Redix.command(@conn, args, timeout: @timeout)
end
