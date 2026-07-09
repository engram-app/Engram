defmodule Engram.Cluster.Readiness do
  @moduledoc """
  Cluster-join readiness for the ALB readiness probe (`/api/health/deep`).

  During a rolling deploy a freshly-booted task must not take traffic while
  its `Phoenix.PubSub` is still per-node — WS clients routed to it would
  silently miss cross-node `note_changed` fan-out until DNSCluster connects
  peers. This module answers "is this node safe to serve?":

    * `:ready` — at least one BEAM peer is connected.
    * `{:ready, :alone}` — no peers, but Cloud Map discovery shows no OTHER
      node either (first-ever task, scale-to-1, disaster recovery — or a
      discovery outage, which deliberately fails open: an unreachable
      resolver must not block boot).
    * `:waiting` — other nodes are discoverable but none is connected yet
      (the deploy boot window). The probe returns 503 so ECS keeps the old
      tasks serving until the new node has joined.
    * `{:ready, :grace_expired}` — still unjoined after the boot grace
      (#{div(:timer.seconds(60), 1000)}s). Passes WITH a warning so a broken
      clustering layer (Cloud Map outage, SG regression, cookie mismatch,
      undistributed node) can never wedge a deploy — the untouched
      `engram-prod-cluster-degraded` alert remains the authority for
      sustained splits. Grace is measured from VM start, so this is strictly
      a *boot-join* gate: a later real split never yanks tasks from the ALB
      (that would turn "degraded fan-out" into an outage).
    * `:not_clustered` — no `DNS_CLUSTER_QUERY` (self-host, dev, test);
      callers skip the check entirely.

  Timing envelope: worst-case gate hold is the 60s grace, well inside ECS
  `health_check_grace_period_seconds` (120s) and the CI ECS-health budget
  (300s, ~160-200s baseline).
  """

  @default_grace_ms :timer.seconds(60)

  @type decision :: :ready | {:ready, :alone} | {:ready, :grace_expired} | :waiting
  @type status :: :not_clustered | decision

  @doc """
  Evaluate readiness against the live node. All collaborators are injectable
  via `opts` for tests (same pattern as `Engram.Drainer`): `:query`, `:peers`,
  `:resolver`, `:self_ip`, `:uptime_ms`, `:grace_ms`.
  """
  @spec check(keyword()) :: status()
  def check(opts \\ []) do
    query = Keyword.get(opts, :query, Application.get_env(:engram, :dns_cluster_query))

    if is_binary(query) do
      peers = Keyword.get(opts, :peers, &Node.list/0).()

      # Steady state (already joined) must never touch DNS: this runs on
      # every /api/health/deep probe, and a hung VPC resolver must not cost
      # the hot path anything once peers are connected.
      other_ips =
        if peers == [] do
          resolver = Keyword.get(opts, :resolver, &resolve_a/1)
          self_ip = Keyword.get_lazy(opts, :self_ip, &self_ip/0)
          resolver.(query) -- List.wrap(self_ip)
        else
          []
        end

      decide(%{
        peers: peers,
        other_ips: other_ips,
        uptime_ms:
          Keyword.get_lazy(opts, :uptime_ms, fn -> elem(:erlang.statistics(:wall_clock), 0) end),
        grace_ms: Keyword.get(opts, :grace_ms, @default_grace_ms)
      })
    else
      :not_clustered
    end
  end

  @doc "Pure gate decision — see the moduledoc for the state semantics."
  @spec decide(%{
          peers: [node()],
          other_ips: [String.t()],
          uptime_ms: non_neg_integer(),
          grace_ms: pos_integer()
        }) :: decision()
  def decide(%{peers: [_ | _]}), do: :ready
  def decide(%{other_ips: []}), do: {:ready, :alone}
  def decide(%{uptime_ms: up, grace_ms: grace}) when up >= grace, do: {:ready, :grace_expired}
  def decide(_state), do: :waiting

  # Cloud Map serves A records only (awsvpc ENI IPv4s; RELEASE_NODE is
  # engram@<ipv4>), so AAAA is intentionally not queried. :inet_res.lookup/4
  # returns [] on any resolution error → fails open to :alone above.
  #
  # Bounded to well under the ALB's 5s health-check timeout: the default
  # retry/timeout (~6s+ worst case) means a hanging VPC resolver would pull
  # every task from rotation instead of failing open. `opts` lets tests
  # point at an unresponsive nameserver to prove the bound holds.
  @doc false
  @resolve_timeout_ms 1_500
  @resolve_retry 1
  def resolve_a(query, opts \\ []) do
    resolve_opts = Keyword.merge([timeout: @resolve_timeout_ms, retry: @resolve_retry], opts)

    query
    |> to_charlist()
    |> :inet_res.lookup(:in, :a, resolve_opts)
    |> Enum.map(&to_string(:inet.ntoa(&1)))
  end

  # "engram@10.30.1.50" → "10.30.1.50". An undistributed node
  # (:nonode@nohost — the env.sh RELEASE_NODE gate failed) yields "nohost",
  # which never matches a resolved IP, so all discovered nodes count as
  # others and the node correctly rides :waiting → :grace_expired.
  defp self_ip do
    case node() |> to_string() |> String.split("@") do
      [_name, host] -> host
      _ -> nil
    end
  end
end
