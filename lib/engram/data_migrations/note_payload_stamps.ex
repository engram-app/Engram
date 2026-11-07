defmodule Engram.DataMigrations.NotePayloadStamps do
  @moduledoc """
  Every indexed note carries a `payload_hash`, which means its Qdrant points
  were verified (or rewritten) to hold its note-level payload. Each pass
  enqueues `ReconcileNotePayloads` per user who still has an unstamped note.

  The correctness case: a DEK rotation before rotations rewrote filter HMACs
  left every point of the user on the old filter key, so type/tag/folder/path
  filters matched nothing. Points are read and only drifted ones are written
  (`set_payload`, no re-embed), so for everyone else this costs reads and a
  row stamp per note.

  The hash side is not re-verified daily. Every writer since #2044 stamps the hash and a
  rotation rewrites and stamps it (`UserDekRotation`); a lost write race
  NULLs a stamp, and `Engram.Bookkeeping.Drain` finds those through the
  partial index `note_index_state_unstamped`. The daily re-verify
  (`reverify?/0`) covers only points without `n`, a Qdrant walk: a rollback's
  re-upserts reopen the ledger by themselves.

  Version 2 (`PayloadV6.version/0` 6) backfills `n`, the note row id, onto
  every v5 point (`ReconcileNotePayloads`). Search does not wait on it (a
  point without `n` is matched by its payload, per point): done is the
  signal the payload-field drop (R3) waits on.
  """
  @behaviour Engram.DataMigration

  alias Engram.Backfill.IdWindows
  alias Engram.Indexing.PayloadV6
  alias Engram.Notes.Note
  alias Engram.Workers.ReconcileNotePayloads

  @impl true
  def name, do: "note_payload_stamps"

  # Follows the payload shape: `PayloadV6.version/0` is 5 at the baseline, so
  # this is 1 today, and a shape bump is a new, not-done version whose pass
  # queues every note with an older `payload_version` (the drain only sees
  # NULL stamps). One source of truth for "points are behind".
  @impl true
  def version, do: PayloadV6.version() - PayloadV6.baseline() + 1

  @doc "Whether this version's pass is done (cached once true, `Engram.DataMigrations.done?/2`)."
  @spec done?() :: boolean()
  def done?, do: Engram.DataMigrations.done?(name(), version())

  # Done when no note is behind AND no point of a live note lacks `n`: a
  # previous-release node can upsert one after its note was stamped (a
  # rolling deploy); `requeue_unbackfilled/0` unstamps those notes, and the
  # next pass queues their users. Its one bounded page runs EVERY pass, not
  # only once the queue drained, so its walk advances while the backfill runs.
  @impl true
  def run_pass, do: run_pass([])

  @doc "`run_pass/0` with the cluster probe's options (tests: `:peers`, `:multicall`)."
  @spec run_pass(keyword()) :: :done | :more | {:more, keyword()}
  def run_pass(opts) do
    cond do
      paused?() -> paused()
      Engram.DataMigrations.done?(name(), version()) -> reverify(opts)
      true -> pass(opts)
    end
  end

  @doc """
  Kill switch: the `payload_backfill` service override (default on), as
  `FileTimes.enabled?/0`. Off, the runner runs no pass (no notes walk, no
  jobs, no Qdrant scroll or unstamp) and the ledger stays open without
  counting as stuck. Below the `n` payload version it is always on.
  """
  @impl true
  def enabled?,
    do:
      PayloadV6.version() < ReconcileNotePayloads.n_version() or
        ReconcileNotePayloads.backfill_enabled?()

  # With the Qdrant gate shut the pass reads nothing (no notes walk, no
  # jobs, no Qdrant scroll or unstamp).
  defp paused?,
    do:
      PayloadV6.version() >= ReconcileNotePayloads.n_version() and
        not Engram.Rebuild.qdrant_open?()

  # Not proven done, so `:more`; but a done ledger (the in-memory cache only,
  # no read) stays done rather than reopening on a paused re-verify.
  defp paused do
    if Engram.DataMigrations.cached_done?(name(), version()), do: :done, else: :more
  end

  # Re-verified daily (`reverify?/0`), so a rollback heals itself: an older
  # release re-upserts points without `n` while the ledger is done, and their
  # stamps stay 6, so only Qdrant can see them. The re-verify runs the Qdrant
  # walk alone (points without `n`, a filtered scroll: after the backfill only
  # orphans and such points match), never the notes walk, which would read
  # every note daily. Finding a live point reopens the ledger (the runner's
  # `:more`) and requeues its user; the hourly passes then heal and close it.
  @impl true
  def reverify?, do: true

  defp reverify(opts) do
    case ReconcileNotePayloads.requeue_unbackfilled(opts) do
      {:ok, requeued} when requeued > 0 -> {:more, users: requeued}
      # Nothing found yet (or Qdrant unreadable): stays done, tomorrow resumes.
      _ -> :done
    end
  end

  defp pass(opts) do
    # The notes primary key in fixed id windows, budgeted and resumable
    # (`IdWindows.heal_pass/4`): done only after one whole walk queued nobody.
    notes = IdWindows.heal_pass(name(), Note, &ReconcileNotePayloads.queue_window/2, [])

    queued = queued(notes)

    case {notes, ReconcileNotePayloads.requeue_unbackfilled(opts)} do
      {:done, :clean} -> :done
      {_, :clean} -> {:more, users: queued}
      {_, {:ok, requeued}} -> {:more, users: queued + requeued}
      # Qdrant unreadable: not proven done, the next pass asks again.
      {_, {:error, _}} -> :more
    end
  end

  # Users the walk's windows queued this pass (`heal_pass/4` counts them as rows).
  defp queued(:done), do: 0
  defp queued({:more, found}), do: Keyword.get(found, :rows, 0)
end
