defmodule EngramWeb.RateLimiter.ETS do
  @moduledoc """
  Per-node ETS Hammer limiter. The default backend (self-host, dev, test, and
  any single-node deploy). `use Hammer` bakes the backend in at compile time;
  runtime backend selection lives in `EngramWeb.RateLimiter`.
  """
  use Hammer, backend: :ets
end
