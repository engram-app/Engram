defmodule Engram.Workers.RotateUserDek do
  @moduledoc """
  T3.7 — Oban worker variant of per-user DEK rotation.

  Args: `%{"user_id" => integer}`.

  Idempotent at the queue layer: uniqueness on `[:user_id]` collapses
  duplicate enqueues. The orchestrator itself is not idempotent
  (T4.5.1) — re-running after success will rotate again to a fresh
  version. Operators should not re-enqueue without need.

  Production-friendly variant of `Mix.Tasks.Engram.RotateUserDek`. Mix
  is preferred for short-lived staging runs (operator gets exit code).
  Oban is preferred for long-running production runs that must survive
  node restarts.

  Return-value semantics:
  - `:ok` — rotation succeeded
  - `{:discard, :user_deleted}` — user does not exist; no retry
  - `{:discard, :half_state_pending}` — prior rotation crashed mid-attachment;
    operator must clear `attachments.dek_version_pending` + lock manually
    before retry. Retrying via Oban would generate a fresh DEK and
    irreversibly corrupt the half-rotated S3 blobs.
  - `{:snooze, 60}` — another rotation is in progress; retry in 60 s
  - `{:error, reason}` — transient failure; Oban retries up to max_attempts
  - `{:discard, {:invalid_args, keys}}` — malformed job args; no retry
  """

  use Oban.Worker,
    queue: :crypto_backfill,
    max_attempts: 3,
    unique: [
      keys: [:user_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Engram.Crypto.UserDekRotation

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}, attempt: attempt})
      when is_integer(user_id) do
    case UserDekRotation.rotate_user(user_id) do
      :ok ->
        :ok

      {:error, :not_found} ->
        {:discard, :user_deleted}

      {:error, :half_state_pending} ->
        {:discard, :half_state_pending}

      {:error, :rotation_in_progress} ->
        :telemetry.execute(
          [:engram, :crypto, :rotate, :dek, :snoozed],
          %{count: 1, attempt: attempt},
          %{user_id: user_id}
        )

        {:snooze, 60}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Tolerant fall-through for malformed args (T3.2-style guard).
  def perform(%Oban.Job{args: args}) do
    {:discard, {:invalid_args, Map.keys(args)}}
  end
end
