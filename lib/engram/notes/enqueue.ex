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
        measurements: %{count: 1}
        metadata:     %{worker: "<label>"}
  """
  require Logger

  @type result :: {:ok, term()} | {:error, term()}
  @type insert_fn :: (term() -> result())

  @doc """
  Calls `insert_fn.(changeset)` (default `&Oban.insert/1`). On
  `{:error, _}`, logs at `:error` with the worker label and emits
  failure telemetry. Always returns the underlying result.
  """
  @spec enqueue(term(), String.t(), insert_fn()) :: result()
  def enqueue(changeset, worker_label, insert_fn \\ &Oban.insert/1)
      when is_binary(worker_label) and is_function(insert_fn, 1) do
    case insert_fn.(changeset) do
      {:ok, _job} = ok ->
        ok

      {:error, reason} = err ->
        Logger.error(
          "oban enqueue failed worker=#{worker_label} reason=#{format_reason(reason)}",
          Engram.Logger.Metadata.with_category(:error, :search, worker: worker_label)
        )

        :telemetry.execute(
          [:engram, :notes, :enqueue, :failed],
          %{count: 1},
          %{worker: worker_label}
        )

        err
    end
  end

  defp format_reason(%Ecto.Changeset{errors: errors}), do: inspect(errors)
  defp format_reason(other), do: inspect(other)
end
