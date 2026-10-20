defmodule Engram.PromEx.Search do
  @moduledoc """
  PromEx plugin for the search pipeline (`Engram.Search.search/4`).

  Subscribes to:

    * `[:engram, :search, :request, :stop]` — metadata `%{status: :ok | :error,
      cross_vault: boolean, rerank: :on | :off}`.
    * `[:engram, :search, :decrypt_failed]` — already registered as a
      Telemetry.Metrics counter in `EngramWeb.Telemetry`; mirroring it
      here so the metric also lands in the PromEx registry without
      double-emitting (telemetry_metrics is fan-out safe — same event
      can drive multiple registries).

  Metrics:

    * `engram_prom_ex_search_request_total` — tags `[:status,
      :cross_vault, :rerank]`. Latency is read from Tempo spans, not a
      histogram here.
    * `engram_prom_ex_search_hits_dropped_total`: sum of `count` from
      `[:engram, :search, :hit_dropped]`, tag `[:reason]`.
    * `engram_prom_ex_search_text_missing_total`: sum of `count` from
      `[:engram, :search, :text_missing]`.
    * `engram_prom_ex_search_hits_total`: sum of `count` from
      `[:engram, :search, :hits]`, every candidate on the Postgres read path
      (the ratio denominator for the two above).

  Cardinality contract: only the booleans/atoms above. NEVER add
  user_id, vault_id, or the query string.
  """

  use PromEx.Plugin

  @stop_event [:engram, :search, :request, :stop]
  @degraded_event [:engram, :search, :degraded]
  @hit_dropped_event [:engram, :search, :hit_dropped]
  @text_missing_event [:engram, :search, :text_missing]
  @hits_event [:engram, :search, :hits]

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :search)

    Event.build(
      :engram_search_event_metrics,
      [
        counter(
          metric_prefix ++ [:request, :total],
          event_name: @stop_event,
          description: "Search requests by status, cross-vault, rerank.",
          tags: [:status, :cross_vault, :rerank]
        ),
        # Search silently fell back to keyword-only because the query embed
        # failed. This is invisible in the metrics above — a degraded search is
        # still `status: :ok` with results — so without this counter an operator
        # whose embedder is slow or down just gets quietly worse search. `reason`
        # is `Search.error_label/1`, deliberately bounded for cardinality.
        counter(
          metric_prefix ++ [:degraded, :total],
          event_name: @degraded_event,
          description: "Searches that degraded to a single leg (embed failure).",
          tags: [:leg, :reason]
        ),
        # Hits dropped, by `reason`: `no_chunk_row` (Qdrant upsert lands
        # before the rows commit; brief per edit, a sustained rate means
        # results are silently going missing), `text_undecryptable`,
        # `note_undecryptable`, `payload_undecryptable` (a pre-text-column
        # row whose payload fallback failed), `vault_inactive`.
        # NOT alerted on yet: the engram-infra ratio alert over search hits
        # (PR #2089 "Infra follow-up") is owed before `:chunk_text_read`
        # flips on, since that flag is what makes these drops reachable.
        sum(
          metric_prefix ++ [:hits_dropped, :total],
          event_name: @hit_dropped_event,
          measurement: :count,
          description: "Search hits dropped, by reason.",
          tags: [:reason]
        ),
        # Task 11.3: hits shown with empty text because neither the chunk row
        # nor the payload carried any. Near zero once the v5 pass has written
        # every row; a rate means rows are missing their text.
        sum(
          metric_prefix ++ [:text_missing, :total],
          event_name: @text_missing_event,
          measurement: :count,
          description: "Search hits with no text in Postgres or the payload."
        ),
        # Every Qdrant candidate on the `:chunk_text_read` path, before any
        # drop: the denominator for the two counters above.
        sum(
          metric_prefix ++ [:hits, :total],
          event_name: @hits_event,
          measurement: :count,
          description: "Search hits read from Postgres, before drops."
        )
      ]
    )
  end
end
