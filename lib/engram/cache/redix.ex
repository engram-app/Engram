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
      start: {Redix, :start_link, [url, redix_opts()]}
    }
  end

  @spec command([String.t()]) :: {:ok, term()} | {:error, term()}
  def command(args), do: Redix.command(@conn, args, timeout: @timeout)

  # `customize_hostname_check` is required for `rediss://` URLs whose server
  # presents a wildcard cert (e.g. AWS ElastiCache/Valkey:
  # `*.cluster.cache.amazonaws.com`). Erlang `:ssl`'s default match_fun is
  # strict literal — it rejects wildcard SANs on leftmost-label hosts like
  # `master.cluster.cache.amazonaws.com` and emits
  # `CLIENT ALERT: Fatal - Handshake Failure` every reconnect (silent cache
  # fail-open in prod). The `:https`-shape match_fun applies RFC 6125
  # wildcard rules. Ignored for plain-tcp `redis://` URLs (no TLS
  # handshake), so unconditional is safe for selfhost.
  defp redix_opts do
    [
      name: @conn,
      sync_connect: false,
      socket_opts: [
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end
end
