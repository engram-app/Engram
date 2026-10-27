defmodule Engram.PromEx.Indexing do
  @moduledoc """
  PromEx plugin for index-maintenance telemetry — currently the rename repath
  worker (`Engram.Workers.RepathNoteIndex`, #746/#753).

  Subscribes to:

    * `[:engram, :indexing, :repath, :stop]` — `%{count}`, metadata
      `%{outcome: :ok | :missing_points | :fallback}`:
        - `:ok`             — points PATCHed in place (the cheap, 0-Voyage path);
          `count` is the number of points repathed.
        - `:missing_points` — embedded note had zero points under the old path
          (benign on rapid multi-rename; a real inconsistency otherwise).
        - `:fallback`       — repath exhausted retries and fell back to a full
          re-embed; `count` is 1 (an event tick).

  Metrics:

    * `engram_prom_ex_indexing_rebuild_halted_total` and
      `engram_prom_ex_indexing_rebuild_drift_parked_total`: the v5 rebuild
      ledger halt (once per off transition) and drift parks (`Engram.Rebuild`).
    * `engram_prom_ex_indexing_rebuild_double_pay_parked_total`: rebuild
      notes parked before a second Voyage payment for the same content.
    * `engram_prom_ex_indexing_rebuild_meter_failed_total`: live ledger debits
      that failed and were carried to the end of the rebuild job.
    * `engram_prom_ex_indexing_rebuild_ledger_{budget,spent}_tokens`: the
      ledger (`Engram.Rebuild.ledger/0`), polled every 60 s on every node
      (aggregate with `max`, never `sum`). Absent until a dry run seals a
      budget. Spend past 1.1x the manifest is `spent > 1.1 * budget / 1.15`.
    * `engram_prom_ex_indexing_rebuild_gated_total{reason}`: rebuild jobs
      snoozed by `Engram.Rebuild.gate/0`, `tokens` (the maintenance bucket
      is spent for the minute) or `qdrant` (the collection is behind).
    * `engram_prom_ex_indexing_repath_total` — counter of repath events by
      `:outcome`. Alert on `:fallback` / `:missing_points` rate; the `:ok` rate
      is the "renames took the cheap path" signal.
    * `engram_prom_ex_indexing_repath_points_total` — sum of `count` by
      `:outcome`. For `:ok` this is total points repathed = the zero-Voyage
      volume saved.
    * `engram_prom_ex_indexing_link_rewrite_failures_total` — counter of
      per-source-note link-rewrite failures from `RewriteNoteLinks`
      (rename propagation, #648/#1231), tagged by `:reason`.
    * `engram_prom_ex_indexing_stale_points_leaked_total` — Qdrant points a
      re-index failed to delete after its chunk rows stopped naming them
      (#1592). Each one is deleted content that stays searchable until
      `OrphanSweep`'s weekly point pass reaps it, so a sustained non-zero rate
      is a correctness signal, not a performance one. Expected flat zero.

    * `engram_prom_ex_indexing_maintenance_embed_tokens_total` — embed tokens
      sent by version rebuilds (a chunker or embed-model bump on unchanged
      content). That spend is ours, never charged to a user's embed cap, so
      this is the only place it is counted. Untagged.

    * `engram_prom_ex_indexing_points_written_total`: Qdrant points written
      by a commit (reused points excluded), tagged by `:kind` (`prose | data |
      frontmatter | drawing | canvas | base`) and `:dense` (`"true" | "false"`).
      Sizes each embed-less lever. `drawing` stays 0 while drawing data is
      dropped; canvas and base are labelled from the note path.

    * `engram_prom_ex_indexing_chunks_total`: chunks per committed pass, tagged
      by `:outcome` (`embedded | reused`); the reuse ratio is
      `reused / (embedded + reused)`.
    * `engram_prom_ex_indexing_frontmatter_keys_skipped_total`: new
      user-added frontmatter keys left out of the payload and `note_attrs`
      because the user is at the per-user key cap (`FrontmatterKeys.cap/0`).
      Untagged. Expected flat zero; a sustained rate means a user (or a
      generator) is minting keys.
    * `engram_prom_ex_indexing_vector_cache_{hits,misses,written_bytes}_total`:
      the vector cache (`Engram.Indexing.VectorCache`). Hit rate is
      hits / (hits + misses); written bytes sizes the table. Untagged.
    * `engram_prom_ex_indexing_vector_cache_skipped_rows_total`: rows the cache
      refused to write, tagged by `:reason` (`rotation | note_deleted`). A
      sustained rate means the cache is not saving the retries it exists for.
    * `engram_prom_ex_indexing_payload_reconcile_total`: notes handled by
      `ReconcileNotePayloads`, tagged by `:outcome` (`checked | drifted |
      rewritten | skipped_v5`). `rewritten / checked` is how much of the
      collection the heal is rewriting; expected near zero outside a rotation.
    * `engram_prom_ex_indexing_payload_reconcile_cancelled_total`: reconcile
      jobs cancelled on a 4xx Qdrant refusal, tagged by `:http_status`
      (100..599, bounded). Any increase means a request Qdrant refuses on
      every attempt (#2138): the hourly re-check would cancel it forever.

  Cardinality contract: only `:outcome`/`:reason`/`:kind`/`:dense` (closed
  enums) and `:http_status` (an HTTP status). NEVER add note_id, user_id, or vault_id.
  """

  use PromEx.Plugin

  require Logger

  @repath_stop_event [:engram, :indexing, :repath, :stop]
  @link_rewrite_failed_event [:engram, :links, :rewrite, :failed]
  @stale_points_leaked_event [:engram, :indexing, :stale_points_leaked]
  @rebuild_halted_event [:engram, :rebuild, :halted]
  @rebuild_drift_event [:engram, :rebuild, :drift_parked]
  @rebuild_double_pay_event [:engram, :rebuild, :double_pay_parked]
  @rebuild_meter_failed_event [:engram, :rebuild, :meter_failed]
  @rebuild_gated_event [:engram, :rebuild, :gated]
  @rebuild_ledger_event [:engram, :rebuild, :ledger]
  @maintenance_embed_event [:engram, :embed, :maintenance]
  @points_written_event [:engram, :indexing, :points_written]
  @chunks_event [:engram, :indexing, :chunks]
  @keys_skipped_event [:engram, :frontmatter_keys, :skipped]
  @vector_cache_lookup_event [:engram, :vector_cache, :lookup]
  @vector_cache_write_event [:engram, :vector_cache, :write]
  @vector_cache_skipped_event [:engram, :vector_cache, :skipped]

  @impl true
  def polling_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    prefix = PromEx.metric_prefix(otp_app, :indexing)

    Polling.build(
      :engram_rebuild_ledger_polling_metrics,
      Keyword.get(opts, :rebuild_ledger_poll_rate, :timer.seconds(60)),
      {__MODULE__, :execute_rebuild_ledger, []},
      [
        last_value(prefix ++ [:rebuild, :ledger, :budget_tokens],
          event_name: @rebuild_ledger_event,
          measurement: :budget_tokens,
          description: "v5 rebuild ledger budget: 1.15x the dry-run manifest's estimated tokens."
        ),
        last_value(prefix ++ [:rebuild, :ledger, :spent_tokens],
          event_name: @rebuild_ledger_event,
          measurement: :spent_tokens,
          description: "Voyage tokens the v5 rebuild pass has debited to its ledger."
        )
      ]
    )
  end

  @doc false
  # One ledger read per tick, on every node. telemetry_poller drops a
  # measurement that raises for good, so a failed read is skipped here; the
  # next tick retries. No ledger (before the dry run seals) emits nothing.
  @spec execute_rebuild_ledger() :: :ok
  def execute_rebuild_ledger do
    case Engram.Rebuild.ledger() do
      %{budget_tokens: budget, spent_tokens: spent} ->
        :telemetry.execute(
          @rebuild_ledger_event,
          %{budget_tokens: budget, spent_tokens: spent},
          %{}
        )

      nil ->
        :ok
    end

    :ok
  rescue
    e -> ledger_skipped(inspect(e.__struct__))
  catch
    kind, _ -> ledger_skipped(Atom.to_string(kind))
  end

  defp ledger_skipped(why) do
    Logger.warning("rebuild ledger poll skipped: #{why}")
    :ok
  end

  @payload_reconcile_event [:engram, :indexing, :payload_reconcile]
  @payload_reconcile_cancelled_event [:engram, :indexing, :payload_reconcile_cancelled]

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :indexing)

    Event.build(
      :engram_indexing_event_metrics,
      [
        counter(
          metric_prefix ++ [:repath, :total],
          event_name: @repath_stop_event,
          description: "Rename repath outcomes from the RepathNoteIndex worker.",
          tags: [:outcome]
        ),
        sum(
          metric_prefix ++ [:repath, :points, :total],
          event_name: @repath_stop_event,
          measurement: :count,
          description:
            "Qdrant points repathed in place by outcome (0-Voyage volume saved on :ok).",
          tags: [:outcome]
        ),
        counter(
          metric_prefix ++ [:link_rewrite, :failures, :total],
          event_name: @link_rewrite_failed_event,
          description:
            "Per-source-note link-rewrite failures (rename propagation, #648/#1231). " <>
              ":reason is a closed set — known pipeline error atoms plus " <>
              ":exception/:other buckets (RewriteNoteLinks.telemetry_failure_reason/1).",
          tags: [:reason]
        ),
        sum(
          metric_prefix ++ [:stale_points_leaked, :total],
          event_name: @stale_points_leaked_event,
          measurement: :count,
          description:
            "Qdrant points a re-index could not delete once its chunk rows stopped " <>
              "naming them (#1592) — deleted content still searchable until OrphanSweep " <>
              "reaps it. Untagged by design; per-note detail is in the log line."
        ),
        sum(
          metric_prefix ++ [:maintenance_embed_tokens, :total],
          event_name: @maintenance_embed_event,
          measurement: :tokens,
          description:
            "Embed tokens sent by version rebuilds (chunker or embed-model bump, content " <>
              "unchanged): our maintenance spend, never charged to a user's embed cap."
        ),
        sum(
          metric_prefix ++ [:points_written, :total],
          event_name: @points_written_event,
          measurement: :count,
          description:
            "Qdrant points written by a commit (reused excluded), by chunk kind and " <>
              "whether the point carries a dense vector.",
          tags: [:kind, :dense]
        ),
        sum(
          metric_prefix ++ [:chunks, :total],
          event_name: @chunks_event,
          measurement: :count,
          description:
            "Chunks a committed indexing pass wrote, by outcome: embedded (new point) or reused (kept in place). reused / (embedded + reused) is the reuse ratio.",
          tags: [:outcome]
        ),
        sum(
          metric_prefix ++ [:frontmatter_keys_skipped, :total],
          event_name: @keys_skipped_event,
          measurement: :count,
          description:
            "New user-added frontmatter keys skipped at the per-user key cap " <>
              "(left out of the payload and note_attrs, never an indexing error)."
        ),
        sum(
          metric_prefix ++ [:vector_cache, :hits, :total],
          event_name: @vector_cache_lookup_event,
          measurement: :hits,
          description: "Dense texts served from the vector cache: Voyage tokens not paid."
        ),
        sum(
          metric_prefix ++ [:vector_cache, :misses, :total],
          event_name: @vector_cache_lookup_event,
          measurement: :misses,
          description: "Dense texts the vector cache did not hold, so Voyage embeds them."
        ),
        sum(
          metric_prefix ++ [:vector_cache, :written_bytes, :total],
          event_name: @vector_cache_write_event,
          measurement: :bytes,
          description: "Ciphertext bytes written to embedding_cache (table growth)."
        ),
        sum(
          metric_prefix ++ [:vector_cache, :skipped_rows, :total],
          event_name: @vector_cache_skipped_event,
          measurement: :rows,
          description:
            "Vector cache rows not written (DEK rotation running or DEK moved on, " <>
              "or the note was deleted mid-embed): vectors a retry pays for again.",
          tags: [:reason]
        ),
        sum(
          metric_prefix ++ [:rebuild, :halted, :total],
          event_name: @rebuild_halted_event,
          measurement: :count,
          description:
            "v5 rebuild ledger halts: once per off transition, when a debit passes the budget."
        ),
        counter(
          metric_prefix ++ [:rebuild, :drift_parked, :total],
          event_name: @rebuild_drift_event,
          description:
            "v5 rebuild notes parked for costing over 1.5x their estimate and 50k tokens."
        ),
        sum(
          metric_prefix ++ [:rebuild, :double_pay_parked, :total],
          event_name: @rebuild_double_pay_event,
          measurement: :count,
          description: "v5 rebuild notes parked before paying Voyage twice for the same content."
        ),
        sum(
          metric_prefix ++ [:rebuild, :meter_failed, :total],
          event_name: @rebuild_meter_failed_event,
          measurement: :count,
          description:
            "v5 rebuild ledger debits that failed live and were carried to the job's end."
        ),
        counter(
          metric_prefix ++ [:rebuild, :gated, :total],
          event_name: @rebuild_gated_event,
          description:
            "v5 rebuild jobs snoozed by the pass's pacing: tokens (bucket spent) or qdrant (behind).",
          tags: [:reason]
        ),
        sum(
          metric_prefix ++ [:payload_reconcile, :total],
          event_name: @payload_reconcile_event,
          measurement: :count,
          description:
            "Notes handled by ReconcileNotePayloads, by outcome (checked, drifted, " <>
              "rewritten, skipped_v5).",
          tags: [:outcome]
        ),
        sum(
          metric_prefix ++ [:payload_reconcile_cancelled, :total],
          event_name: @payload_reconcile_cancelled_event,
          measurement: :count,
          description: "ReconcileNotePayloads jobs cancelled on a 4xx Qdrant refusal, by status.",
          tags: [:http_status]
        )
      ]
    )
  end
end
