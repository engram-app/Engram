defmodule EngramWeb.RateLimiter.Redis do
  @moduledoc """
  Cluster-shared Redis Hammer limiter. SaaS prod opts into this (ElastiCache,
  engram-infra#158) so per-plan/§G and Voyage-quota counters are exact across
  all nodes instead of N×-per-node. Started only when configured; the façade
  fails open if the store is unreachable.

  `:prefix` and `:timeout` are `use Hammer` (compile-time) options, not Redix
  start options — the only valid runtime start option is `:url` (see
  `start_opts/1`). The 250ms command timeout keeps the façade's fail-open fast
  when Redis is partitioned (Hammer/Redix default is `:infinity`).
  """
  use Hammer, backend: Hammer.Redis, prefix: "engram_rl:", timeout: 250

  @doc """
  Runtime start options for the limiter, derived from `REDIS_URL`.

  Only `:url` is a `Hammer.Redis`-specific start option; everything else is
  popped and forwarded to `Redix.start_link/1`, which validates its schema
  strictly and rejects unknown keys (a bad option crashes the limiter on
  boot). The key prefix and command timeout are compiled in via the `use`
  opts above.

  For `rediss://` URLs ONLY: append `:socket_opts` with
  `customize_hostname_check` so wildcard certs (AWS ElastiCache/Valkey:
  `*.cluster.cache.amazonaws.com`) negotiate TLS successfully. Erlang
  `:ssl`'s default match_fun is strict literal — it rejects wildcard SANs
  on leftmost-label hosts like `master.cluster.cache.amazonaws.com` and
  emits `CLIENT ALERT: Fatal - Handshake Failure` every reconnect.

  MUST be gated on the `rediss://` scheme: for plain-tcp `redis://` URLs
  Redix passes `socket_opts` directly to `:gen_tcp.connect/4`, which
  validates strictly and rejects `customize_hostname_check` (an `:ssl`
  option) with ArgumentError → boot-loops the limiter → crashes the app
  supervisor on staging-fastraid + selfhost. The original `Pull #496`
  claimed "unconditional is safe" — wrong.
  """
  @spec start_opts(String.t()) :: keyword()
  def start_opts(redis_url) when is_binary(redis_url) do
    base = [url: redis_url]

    if String.starts_with?(redis_url, "rediss://"), do: base ++ tls_opts(), else: base
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
