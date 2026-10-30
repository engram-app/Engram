defmodule Engram.Notes.Enqueue do
  @moduledoc """
  Wraps `Oban.insert/1` so enqueue failures are observable.

  T3-audit H3 — pre-fix, four sites in `Engram.Notes` discarded the
  `Oban.insert/1` return. A failed enqueue (queue saturated, invalid
  changeset, Oban migration drift) logged nothing and emitted nothing,
  so embed/delete jobs could vanish silently. This module logs +
  emits telemetry on failure while leaving the success path identical.

  ## Telemetry

      [:engram, :notes, :enqueue, :failed]
        measurements: %{count: 1}   # jobs lost (a failed bulk chunk: its size)
        metadata:     %{worker: "<label>"}

      [:engram, :notes, :enqueue, :lookup_failed]
        measurements: %{count: n}   # notes that fell back to unfiltered enqueue
        metadata:     %{worker: "<label>"}
  """
  alias Engram.{Batch, Jobs}
  alias Engram.Logger.Metadata

  require Logger

  @type result :: {:ok, term()} | {:error, term()}
  @type insert_fn :: (term() -> result())

  @doc """
  Calls `insert_fn.(changeset)` (default `&Oban.insert/1`). On
  `{:error, _}`, logs at `:error` with the worker label and emits
  failure telemetry. Always returns the underlying result.
  """
  @spec enqueue(term(), String.t(), insert_fn()) :: result() | {:ok, :skipped}
  def enqueue(changeset, worker_label, insert_fn \\ &Oban.insert/1)

  # A worker's builder can decline the job by returning `:skip`. No-op here so
  # no enqueue site needs its own guard.
  def enqueue(:skip, worker_label, _insert_fn) when is_binary(worker_label),
    do: {:ok, :skipped}

  def enqueue(changeset, worker_label, insert_fn)
      when is_binary(worker_label) and is_function(insert_fn, 1) do
    case insert_fn.(changeset) do
      {:ok, _job} = ok ->
        ok

      {:error, reason} = err ->
        Logger.error(
          "oban enqueue failed worker=#{worker_label} reason=#{format_reason(reason)}",
          Metadata.with_category(:error, :search, worker: worker_label)
        )

        :telemetry.execute(
          [:engram, :notes, :enqueue, :failed],
          %{count: 1},
          %{worker: worker_label}
        )

        err
    end
  end

  @doc """
  Bulk form of `enqueue/3` for a post-commit side effect: one
  `Oban.insert_all/1` per `Engram.Batch.insert_rows/0` jobs instead of one
  insert (one pool checkout) per job. Same contract as `enqueue/3`: it never
  raises. A failed chunk is retried once; if it fails again it logs and emits
  the failure telemetry (`count` = jobs lost) and the rest still go in.
  `:skip` entries are dropped, as in `enqueue/3`.

  A retry after an ambiguous failure (the first insert committed but the
  client saw an error) can double-insert, so every caller's job must be
  idempotent. Callers are post-commit only, never inside a transaction.

  `Oban.insert_all/1` ignores `unique`: callers that relied on it drop
  already-pending ids first (`reject_pending/4`).
  """
  @spec enqueue_all([term()], String.t()) :: :ok
  def enqueue_all(changesets, worker_label) when is_binary(worker_label) do
    changesets
    |> Enum.reject(&(&1 == :skip))
    |> Enum.chunk_every(Batch.insert_rows())
    |> Enum.each(&insert_chunk(&1, worker_label))
  end

  defp insert_chunk(chunk, worker_label) do
    _inserted = Oban.insert_all(chunk)
    :ok
  rescue
    _first ->
      retry_chunk(chunk, worker_label)
  end

  defp retry_chunk(chunk, worker_label) do
    _inserted = Oban.insert_all(chunk)
    :ok
  rescue
    e ->
      Logger.error(
        "oban bulk enqueue failed worker=#{worker_label} jobs=#{length(chunk)} reason=#{Metadata.safe_reason(e)}",
        Metadata.with_category(:error, :search, worker: worker_label)
      )

      :telemetry.execute(
        [:engram, :notes, :enqueue, :failed],
        %{count: length(chunk)},
        %{worker: worker_label}
      )

      :ok
  end

  @doc """
  `Engram.Jobs.reject_pending/3` that never raises, for the same post-commit
  callers as `enqueue_all/2`. If the lookup fails, every id is returned: a
  duplicate job is harmless, a lost one is not. The failure logs and emits the
  same telemetry.
  """
  @spec reject_pending(module(), [term()], keyword(), String.t()) :: [term()]
  def reject_pending(worker, ids, opts, worker_label) do
    lookup = Application.get_env(:engram, :enqueue_reject_pending, &Jobs.reject_pending/3)
    lookup.(worker, ids, opts)
  rescue
    e ->
      Logger.error(
        "oban pending lookup failed worker=#{worker_label} reason=#{Metadata.safe_reason(e)}; queueing all",
        Metadata.with_category(:error, :search, worker: worker_label)
      )

      :telemetry.execute(
        [:engram, :notes, :enqueue, :lookup_failed],
        %{count: length(ids)},
        %{worker: worker_label}
      )

      ids
  end

  defp format_reason(%Ecto.Changeset{errors: errors}), do: inspect(errors)
  defp format_reason(other), do: inspect(other)
end
