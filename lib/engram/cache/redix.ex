defmodule Engram.Cache.Redix do
  @moduledoc """
  Pool of Redix connections backing `Engram.Cache` in `:redis` mode —
  separate from the rate limiter's Hammer-managed connection; same
  `REDIS_URL`, distinct logical pool.

  A single connection was a per-node serialization point: every cache round
  trip funneled through one process + one socket, and under load the 250ms
  command timeout flipped the façade to fail-open exactly when traffic was
  heaviest. Callers now hash onto one of #{8} named connections by pid.

  Started from `Engram.Application` only when the cache backend is `:redis`.
  `sync_connect: false` so boot never blocks on Redis reachability; the façade
  fails open while connections (re)establish. The 250ms command timeout
  keeps fail-open fast under a partition (Redix default is `:infinity`).
  """

  @pool_size 8
  @timeout 250

  # Closed set of pool member names, built at compile time — no runtime
  # atom creation.
  @conn_names Enum.map(0..(@pool_size - 1), &:"engram_cache_redix_#{&1}")

  def child_spec(opts) do
    url = Keyword.fetch!(opts, :url)

    children =
      for i <- 0..(@pool_size - 1) do
        %{
          id: {__MODULE__, i},
          start: {Redix, :start_link, [url, redix_opts(conn_name(i), url)]}
        }
      end

    %{
      id: __MODULE__,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
      type: :supervisor
    }
  end

  @spec command([String.t()]) :: {:ok, term()} | {:error, term()}
  def command(args), do: Redix.command(pool_conn_name(), args, timeout: @timeout)

  @doc """
  Deterministic pool member for the calling process. Pid-hash keeps a
  caller's commands ordered on one connection while spreading load.
  """
  @spec pool_conn_name() :: atom()
  def pool_conn_name, do: conn_name(:erlang.phash2(self(), @pool_size))

  @doc "All pool member names, in index order."
  # No @spec: dialyzer's success typing is the literal 8-atom list and a
  # [atom()] spec trips contract_supertype under the strict flags.
  def pool_conn_names, do: @conn_names

  defp conn_name(i), do: Enum.at(@conn_names, i)

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
  defp redix_opts(name, url) do
    base = [name: name, sync_connect: false]

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
