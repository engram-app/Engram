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
      start: {Redix, :start_link, [url, redix_opts(url)]}
    }
  end

  @spec command([String.t()]) :: {:ok, term()} | {:error, term()}
  def command(args), do: Redix.command(@conn, args, timeout: @timeout)

  # `customize_hostname_check` is required for `rediss://` URLs whose server
  # presents a wildcard cert (e.g. AWS ElastiCache/Valkey:
  # `*.cluster.cache.amazonaws.com`). Erlang `:ssl`'s default match_fun is
  # strict literal — it rejects wildcard SANs on leftmost-label hosts like
  # `master.cluster.cache.amazonaws.com` and emits
  # `CLIENT ALERT: Fatal - Handshake Failure` every reconnect.
  #
  # MUST be gated on the `rediss://` scheme: for plain-tcp `redis://` URLs
  # Redix passes `socket_opts` directly to `:gen_tcp.connect/4`, which
  # validates strictly and rejects `customize_hostname_check` (an `:ssl`
  # option) with ArgumentError → boot-loops the cache/limiter process →
  # crashes the app supervisor on staging-fastraid + selfhost.
  # The original `Pull #496` claimed "unconditional is safe" — wrong.
  defp redix_opts(url) do
    base = [name: @conn, sync_connect: false]

    if String.starts_with?(url, "rediss://"), do: base ++ tls_opts(), else: base
  end

  defp tls_opts do
    [
      socket_opts: [
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end
end
