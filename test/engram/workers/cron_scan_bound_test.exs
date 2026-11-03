defmodule Engram.Workers.CronScanBoundTest do
  @moduledoc """
  Job Load Audit 2026-11-03, rule 1: no maintenance job may scan a table
  without an index-bounded predicate AND a per-run row cap.

  A scheduled worker is a recurring read on a 4 GB database whose working set
  is its page cache, so an O(table) read evicts the hot set and swaps. This is
  the ratchet: every worker in the crontab must be classified here, with the
  bound that keeps it small. A new cron fails this test until someone writes
  down what bounds it, which is the whole mechanism (it judges nothing about
  whether the bound is true; the reviewer does).

  `@known_unbounded` is the audit's open list: shipped, measured, with an
  owner. It must only shrink.
  """
  use ExUnit.Case, async: true

  @bounded %{
    Engram.Workers.ReleaseRebuildHeld =>
      "oban_jobs rows held by the rebuild (state/queue index), a no-op while the rebuild is on",
    Engram.Workers.BookkeepingDrain =>
      "partial indexes *_envelope_legacy, note_index_state_unstamped, notes_unresolved_folder, *_link_keys_stale; 100 users per probe",
    Engram.Workers.WarmCrdtHeads =>
      "partial index note_bodies_crdt_head_null, 5,000 candidates per run",
    Engram.Workers.CrdtBloatSweep =>
      "reads note_index_state (narrow) once NoteSizes is done; one aggregate per hour",
    Engram.Workers.DataMigrationsRunner =>
      "id windows (IdWindows.heal_pass) with a 240 s budget; daily re-verify only for reopening ledgers",
    Engram.Workers.ReconcileEmbeddings =>
      "partial index notes_reconcile_due, 1,000-row pages; daily budget sweep reads note_index_state",
    Engram.Workers.OrphanSweep =>
      "250 scroll pages and 250 chunk pages per run, resuming at a persisted cursor",
    Engram.Workers.DailySnapshot =>
      "copies vaults whose change_seq is unchanged; note counts and bytes from note_index_state",
    Engram.Workers.PostHogPersonSync =>
      "account facts; note counts and bytes from note_index_state (narrow), small tables otherwise",
    Engram.Workers.ClientLogsPruner => "batched deletes, 20 batches per run",
    Engram.Workers.IdempotencyPrune => "batched deletes by expiry",
    Engram.Workers.VectorCachePrune => "batched deletes by age",
    Engram.Workers.AnalyticsEventsPrune => "batched deletes by age",
    Engram.Workers.InstallPingsPruner => "11-row table, delete by age",
    Engram.Billing.Workers.OverrideExpirySweep => "expired overrides only, by expiry",
    Engram.Workers.CleanupDeviceAuthWorker => "expired codes by expiry",
    Engram.Workers.AttachmentUploadExpiry => "idle upload sessions by age (tiny table)",
    Engram.Workers.AttachmentBlobGC => "soft-deleted attachments by deleted_at, batched",
    Engram.Workers.ExportExpirySweep => "export rows by expiry (tiny table)",
    Engram.Workers.FinalizeRevisionSweep => "stranded outbox rows by age",
    Engram.Workers.DrainStrandedTails => "crdt_update_log tails (91 rows)"
  }

  # Not bounded by an index and a row cap, measured (Job Load Audit 2026-11-03,
  # rows 6-9, 11). Each is daily and off-peak; the audit lists the fix.
  @known_unbounded %{
    Engram.Workers.ReconcileAttachmentBlobs => "per-vault fan-out over 60k attachments, daily",
    Engram.Workers.OriginAbuseSweep => "daily question over a 3-day window",
    Engram.Workers.InactivityCleanup => "daily, per-user steps with early exit",
    Engram.Workers.LegalNoticeDispatch => "small tables, hourly",
    Engram.Workers.TelemetryHeartbeat => "no table scan",
    Engram.Workers.CimdRefresh => "small tables",
    Engram.Workers.CimdJwksSchedule => "small tables",
    Engram.Billing.Workers.PaddleReconcile => "subscriptions by status (small)"
  }

  test "every cron worker declares what bounds its scan" do
    cron =
      Engram.Test.ObanWorkers.crontab()
      |> Enum.map(fn {_expr, worker} -> worker end)
      |> Enum.uniq()

    unclassified =
      Enum.reject(cron, &(Map.has_key?(@bounded, &1) or Map.has_key?(@known_unbounded, &1)))

    assert unclassified == [],
           "cron workers with no declared scan bound (add to @bounded with the index and the " <>
             "per-run cap, never to @known_unbounded): #{inspect(unclassified)}"
  end

  # The open list only shrinks: pinned at its size when it was written.
  test "the known-unbounded list does not grow" do
    assert map_size(@known_unbounded) <= 8
  end

  test "the classification lists no worker that left the crontab" do
    cron = Engram.Test.ObanWorkers.crontab() |> Enum.map(&elem(&1, 1)) |> MapSet.new()
    listed = Map.keys(@bounded) ++ Map.keys(@known_unbounded)
    assert Enum.reject(listed, &MapSet.member?(cron, &1)) == []
  end
end
