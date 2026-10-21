defmodule Engram.PromEx.ZeroInit do
  @moduledoc """
  Emits a 0 for every alerted counter series once at boot, right after
  `Engram.PromEx` attaches its handlers.

  A counter series only exists from its first event, and Prometheus'
  `increase()` needs a sample before the step: a series whose first sample
  is already 1 reads as no increase. So an isolated failure after a deploy
  (one rotation's `requeue_failed`) never paged (engram-infra #1525 review).
  Seeding 0 makes every alerted series exist from boot.

  A series is the FULL label set, so each entry names the exact label values
  an emit site sends (for the rotation, the `table`/`phase`/`status` of
  `UserDekRotation`). Add one here when an alert selects a new label value
  or a site adds a pair.
  """

  @search_hits [:engram, :search, :hits]
  @search_text_missing [:engram, :search, :text_missing]
  @search_hit_dropped [:engram, :search, :hit_dropped]
  @row_failed [:engram, :crypto, :rotate, :dek, :row_failed]
  @payload_reconcile [:engram, :indexing, :payload_reconcile]

  # The `hit_dropped` reasons the undecryptable-text alert selects
  # (`Engram.Search`): a key or ciphertext fault, never an expected orphan.
  @undecryptable [:text_undecryptable, :note_undecryptable, :payload_undecryptable]

  # Every try_rewrap site's {table, phase} (both_deks_failed).
  @rewrap_sites [
    {:vaults, :sweep_vaults},
    {:frontmatter_keys, :sweep_frontmatter_keys},
    {:attachments, :sweep_attachments_blob},
    {:attachments, :sweep_attachments_metadata},
    {:note_links, :sweep_note_links},
    {:chunks, :sweep_chunk_texts},
    {:qdrant, :sweep_qdrant},
    {:vault_index_update_log, :sweep_vault_index_update_log},
    {:notes, :sweep_notes},
    {:crdt_update_log, :sweep_notes}
  ]

  @doc false
  def child_spec(_arg), do: %{Task.child_spec(&run/0) | id: __MODULE__}

  @doc "`{event, measurements, metadata}` for each seeded series."
  def series do
    rotate =
      [
        {:chunks, :post_flip_index_repairs, :remap_failed},
        {:qdrant, :sweep_qdrant, :requeue_failed},
        {:qdrant, :sweep_qdrant, :after_flip}
        | for({table, phase} <- @rewrap_sites, do: {table, phase, :both_deks_failed})
      ]

    rotate_series =
      for {table, phase, status} <- rotate,
          do: {@row_failed, %{count: 0}, %{table: table, phase: phase, status: status}}

    reconcile_series =
      for outcome <- [:checked, :drifted, :rewritten, :skipped_v5],
          do: {@payload_reconcile, %{count: 0}, %{outcome: outcome}}

    # `sum` metrics over `count`: a 0 adds nothing to the total.
    search_series =
      [{@search_hits, %{count: 0}, %{}}, {@search_text_missing, %{count: 0}, %{}}] ++
        for reason <- @undecryptable,
            do: {@search_hit_dropped, %{count: 0}, %{reason: reason}}

    search_series ++ rotate_series ++ reconcile_series
  end

  @doc "The same series as Prometheus names them: `{metric, %{label => value}}`."
  def prometheus_series do
    for {event, _measurements, meta} <- series() do
      metric =
        case event do
          @search_hits -> "engram_prom_ex_search_hits_total"
          @search_text_missing -> "engram_prom_ex_search_text_missing_total"
          @search_hit_dropped -> "engram_prom_ex_search_hits_dropped_total"
          @row_failed -> "engram_prom_ex_crypto_rotate_row_failed_total"
          @payload_reconcile -> "engram_prom_ex_indexing_payload_reconcile_total"
        end

      {metric, Map.new(meta, fn {k, v} -> {k, to_string(v)} end)}
    end
  end

  @doc "Emits each series' 0."
  def run do
    for {event, measurements, meta} <- series(), do: :telemetry.execute(event, measurements, meta)
    :ok
  end
end
