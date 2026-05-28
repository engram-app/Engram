defmodule EngramWeb.RateLimiter.Redis do
  @moduledoc """
  Cluster-shared Redis Hammer limiter. SaaS prod opts into this (ElastiCache,
  engram-infra#158) so per-plan/§G and Voyage-quota counters are exact across
  all nodes instead of N×-per-node. Started only when configured; the façade
  fails open if the store is unreachable.
  """
  use Hammer, backend: Hammer.Redis
end
