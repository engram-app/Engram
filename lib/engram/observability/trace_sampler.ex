defmodule Engram.Observability.TraceSampler do
  @moduledoc """
  Root-span sampler that drops health-check / scrape traffic outright, then
  delegates every other trace to the standard ratio sampler.

  Installed as the `root:` sampler under `:parent_based` (see `runtime.exs`),
  so a `:drop` here cascades: the request's child spans (Phoenix, Ecto)
  inherit `not_recording` and are never built or exported. That keeps the
  ~96% of trace volume that is liveness/readiness probes and the Prometheus
  scrape out of Tempo — without touching any real-endpoint trace.

  The path lives in the `:"url.path"` attribute, which `opentelemetry_bandit`
  sets at span *start* (so it is present at sample time). Matching is exact:
  `/api/health` drops but `/api/healthz` does not. Only root spans are
  evaluated (`:parent_based` consults this sampler solely when there is no
  parent), so a real trace whose *child* span happens to carry `url.path=/`
  (e.g. an MCP call) is unaffected.

  ## Deliberate limitations (head sampling)

  The decision is made at span start, before status or duration are known, so:

    * It drops probe paths **unconditionally** — a slow or 5xx health check
      emits no trace either. Health-check failures are diagnosed via the ALB
      `UnHealthyHostCount` alarm, 5xx metrics, and logs, not traces.
    * It only fires on **root** spans. A probe request carrying an inbound
      `traceparent` would be routed by `:parent_based` to a remote-parent
      sampler and bypass the drop. Our probes (ALB, Prometheus/Alloy scrape,
      Grafana synthetic) send no trace context, so this does not arise.

  Bare `/` is intentionally **not** dropped: on self-host the backend serves
  the SPA index at `/` (`get "/", SpaController`), so dropping it would lose
  real page-load traces. On SaaS `/` is low-volume ALB/default traffic that
  we accept tracing — the three probe paths already carry the ~96% of volume.
  """

  @behaviour :otel_sampler

  @drop_paths MapSet.new(~w(
    /metrics
    /api/health
    /api/health/deep
    /socket/origin-probe/websocket
  ))

  @path_key :"url.path"

  @impl :otel_sampler
  def setup(%{ratio: ratio}) do
    %{ratio: :otel_sampler_trace_id_ratio_based.setup(ratio)}
  end

  @impl :otel_sampler
  def description(_config), do: <<"EngramTraceSampler">>

  # A repo.query as a ROOT span is background-poller noise: request-bound Ecto
  # spans always hang off the Bandit server span, so the only orphan query
  # roots are Oban's ~1s staging poll (engram.repo.query:oban_jobs/oban_peers)
  # and its source-less begin/commit siblings. They dominated Tempo volume and
  # buried real traces (2026-07-14). Prefix match keeps every :source variant.
  @repo_query_prefix "engram.repo.query"

  @impl :otel_sampler
  def should_sample(ctx, trace_id, links, span_name, span_kind, attributes, config) do
    if drop?(attributes) or orphan_query?(span_name) do
      {:drop, [], :otel_span.tracestate(:otel_tracer.current_span_ctx(ctx))}
    else
      :otel_sampler_trace_id_ratio_based.should_sample(
        ctx,
        trace_id,
        links,
        span_name,
        span_kind,
        attributes,
        config.ratio
      )
    end
  end

  @doc """
  True when the span's `url.path` is a drop-listed noise path. Total by
  design — runs on the hot path of every root span, so any unexpected
  attribute shape returns `false` rather than raising.
  """
  @spec drop?(term()) :: boolean()
  def drop?(attributes) do
    case lookup_path(attributes) do
      path when is_binary(path) -> MapSet.member?(@drop_paths, path)
      _ -> false
    end
  end

  defp lookup_path(attributes) when is_map(attributes), do: Map.get(attributes, @path_key)
  defp lookup_path(_), do: nil

  defp orphan_query?(span_name) when is_binary(span_name),
    do: String.starts_with?(span_name, @repo_query_prefix)

  # opentelemetry passes span names as atoms or iodata in some paths — treat
  # anything non-binary as not-a-query rather than raising on the hot path.
  defp orphan_query?(_), do: false
end
