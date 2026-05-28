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

  Only `:url` is a valid `Hammer.Redis` start option; everything else is popped
  and forwarded to `Redix.start_link/1`, which validates its schema strictly and
  rejects unknown keys (a bad option crashes the limiter on boot). The key
  prefix and command timeout are compiled in via the `use` opts above.
  """
  @spec start_opts(String.t()) :: [{:url, String.t()}]
  def start_opts(redis_url) when is_binary(redis_url), do: [url: redis_url]
end
