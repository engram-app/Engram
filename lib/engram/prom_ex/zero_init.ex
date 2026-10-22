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
  @reconcile_cancelled [:engram, :indexing, :payload_reconcile_cancelled]
  @rebuild_halted [:engram, :rebuild, :halted]
  @rebuild_meter_failed [:engram, :rebuild, :meter_failed]
  @rebuild_double_pay [:engram, :rebuild, :double_pay_parked]

  # The 4xx statuses Qdrant answers a request it will refuse on every retry:
  # 400 (strict mode's unindexed filter, #2138, or a bad shape), 404 (no
  # collection), 413 (body too large), 422 (invalid payload).
  @reconcile_cancel_statuses [400, 404, 413, 422]

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
        {:qdrant, :sweep_qdrant, :after_flip},
        {:qdrant, :sweep_qdrant, :guard_rebuild}
        | for({table, phase} <- @rewrap_sites, do: {table, phase, :both_deks_failed})
      ]

    rotate_series =
      for {table, phase, status} <- rotate,
          do: {@row_failed, %{count: 0}, %{table: table, phase: phase, status: status}}

    reconcile_series =
      for outcome <- [:checked, :drifted, :rewritten, :skipped_v5],
          do: {@payload_reconcile, %{count: 0}, %{outcome: outcome}}

    cancelled_series =
      for status <- @reconcile_cancel_statuses,
          do: {@reconcile_cancelled, %{count: 0}, %{http_status: status}}

    # `sum` metrics over `count`: a 0 adds nothing to the total.
    search_series =
      [{@search_hits, %{count: 0}, %{}}, {@search_text_missing, %{count: 0}, %{}}] ++
        for reason <- @undecryptable,
            do: {@search_hit_dropped, %{count: 0}, %{reason: reason}}

    rebuild_series =
      for event <- [@rebuild_halted, @rebuild_meter_failed, @rebuild_double_pay],
          do: {event, %{count: 0}, %{}}

    search_series ++ rotate_series ++ reconcile_series ++ cancelled_series ++ rebuild_series
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
          @reconcile_cancelled -> "engram_prom_ex_indexing_payload_reconcile_cancelled_total"
          @rebuild_halted -> "engram_prom_ex_indexing_rebuild_halted_total"
          @rebuild_meter_failed -> "engram_prom_ex_indexing_rebuild_meter_failed_total"
          @rebuild_double_pay -> "engram_prom_ex_indexing_rebuild_double_pay_parked_total"
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
