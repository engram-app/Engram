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
    * `engram_prom_ex_search_post_filter_total`: `[:engram, :search,
      :post_filter]`, tags `[:rounds, :short]`.
    * `engram_prom_ex_search_phrase_checked_total` and
      `..._phrase_promoted_total`: `checked` / `promoted` of
      `[:engram, :search, :phrase_check]`.
    * `engram_prom_ex_search_name_terms_scan_capped_total`: sum of `count`
      from `[:engram, :search, :name_terms, :scan_capped]`, tag `[:kind]`
      (0 notes, 1 folders): query terms whose name-terms scan hit its cap
      before its live budget, i.e. dead rows outran the sweep.
    * Name-index self-heal outcomes (`@heal_events`), each a sum of `count`
      with tag `[:reason]`: `engram_prom_ex_search_name_terms_skipped_total`
      (`[:engram, :name_terms, :skipped]`: refs parked for good, a name that
      never decrypts or a key that never loads) and
      `engram_prom_ex_search_name_terms_deferred_total`
      (`[:engram, :name_terms, :deferred]`: refs left stale on a transient
      key error, `Engram.Crypto.key_outcome/1` `:later`, retried by the
      drain), and the same pair for the S2 name backfill
      (`engram_prom_ex_search_note_name_skipped_total` /
      `_deferred_total`, `[:engram, :note_name, :skipped | :deferred]`,
      `Engram.Workers.BackfillNoteNames`). A steady deferred rate is a user
      whose key keeps failing.

  Cardinality contract: only the booleans/atoms above. NEVER add
  user_id, vault_id, or the query string.
  """

  use PromEx.Plugin

  @stop_event [:engram, :search, :request, :stop]
  @degraded_event [:engram, :search, :degraded]
  @hit_dropped_event [:engram, :search, :hit_dropped]
  @text_missing_event [:engram, :search, :text_missing]
  @hits_event [:engram, :search, :hits]
  @text_stale_event [:engram, :search, :text_stale]
  @phrase_check_event [:engram, :search, :phrase_check]
  @post_filter_event [:engram, :search, :post_filter]
  @name_terms_capped_event [:engram, :search, :name_terms, :scan_capped]

  # Self-heal outcomes of the name indexes, one sum per event, tag `reason`:
  # `{metric, event, description}`. Add a name index's pair here.
  @heal_events [
    {:name_terms_skipped, [:engram, :name_terms, :skipped],
     "Name-terms refs parked for good (never decrypts, key never loads), by reason."},
    {:name_terms_deferred, [:engram, :name_terms, :deferred],
     "Name-terms refs left stale on a transient key error, retried by the drain, by reason."},
    {:note_name_skipped, [:engram, :note_name, :skipped],
     "Note/attachment/folder names parked for good (never decrypts, key never loads), by reason."},
    {:note_name_deferred, [:engram, :note_name, :deferred],
     "Note/attachment/folder names left for a later walk on a key that did not load, by reason."}
  ]

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
        # The name leg (`Search.NameTerms.hits/3`): a query term whose
        # bounded scan (2,000 postings) ended before 500 live ones. Zero in
        # steady state; a rate means dead rows outran the delete hooks and
        # the drain's orphan sweep, and a live name may be missed.
        sum(
          metric_prefix ++ [:name_terms_scan_capped, :total],
          event_name: @name_terms_capped_event,
          measurement: :count,
          description: "Name-leg query terms whose scan hit its cap before its live budget.",
          tags: [:kind]
        ),
        # A `:too_wide` filter (immutable chunk index): the search ran over
        # the whole tenant and post-filtered in Postgres. `rounds` 2 is the
        # one widen (16x); `short` true means the page came back under its
        # limit while Qdrant had more, i.e. the round cap cost recall.
        counter(
          metric_prefix ++ [:post_filter, :total],
          event_name: @post_filter_event,
          description: "Post-filtered (too-wide) searches, by Qdrant rounds and short page.",
          tags: [:rounds, :short]
        ),
        # Hits dropped, by `reason`: `no_chunk_row` (Qdrant upsert lands
        # before the rows commit; brief per edit, a sustained rate means
        # results are silently going missing), `text_undecryptable`,
        # `note_undecryptable`, `payload_undecryptable` (a pre-text-column
        # row whose payload fallback failed), `vault_inactive`.
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
        # Hits whose note was edited since its index: the text re-derived
        # from the content no longer matches the row's checksum, so the hit
        # shows the current chunk at its position. A sustained rate means
        # notes are left unindexed after edits.
        sum(
          metric_prefix ++ [:text_stale, :total],
          event_name: @text_stale_event,
          measurement: :count,
          description: "Search hits shown with text re-derived after an edit since index."
        ),
        # Every Qdrant candidate search reads from Postgres, before any drop:
        # the denominator for the two counters above.
        sum(
          metric_prefix ++ [:hits, :total],
          event_name: @hits_event,
          measurement: :count,
          description: "Search hits read from Postgres, before drops."
        ),
        # Quoted-phrase check (`Search.PhraseCheck`): candidates whose text was
        # checked, and how many a match moved up. No query text, no tags.
        sum(
          metric_prefix ++ [:phrase_checked, :total],
          event_name: @phrase_check_event,
          measurement: :checked,
          description: "Search candidates checked for a quoted phrase."
        ),
        sum(
          metric_prefix ++ [:phrase_promoted, :total],
          event_name: @phrase_check_event,
          measurement: :promoted,
          description: "Search candidates a quoted-phrase match moved up."
        )
      ] ++ heal_metrics(metric_prefix)
    )
  end

  defp heal_metrics(metric_prefix) do
    for {name, event, description} <- @heal_events do
      sum(metric_prefix ++ [name, :total],
        event_name: event,
        measurement: :count,
        description: description,
        tags: [:reason]
      )
    end
  end
end
