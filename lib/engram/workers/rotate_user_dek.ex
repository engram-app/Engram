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
  - `{:snooze, 3600}` — the v5 rebuild is `on`; nothing written
  - `{:error, reason}` — transient failure; Oban retries up to max_attempts
  - `{:discard, {:invalid_args, keys}}` — malformed job args; no retry
  """

  use Oban.Worker,
    queue: :crypto_backfill,
    max_attempts: 3,
    unique: [
      keys: [:user_id],
      states: :incomplete
    ]

  alias Engram.Crypto.UserDekRotation

  # 60 min, the Lifeline `rescue_after` ceiling — the longest value that is
  # not dead code. Generous because this queue is operator-triggered and
  # not user-facing, so a held slot costs little.
  #
  # A kill here is survivable but not free. The note sweep is designed to
  # resume: `dek_version_pending` is written in its own transaction as a
  # crash marker before the flip, so a retry picks up where it stopped.
  # The ATTACHMENT phase is not — a crash mid-attachment leaves
  # `:half_state_pending`, which `RotationLock.acquire/1` then refuses
  # until an operator clears it by hand. The lock itself never strands:
  # it is a `pg_advisory_xact_lock`, released with its transaction.
  #
  # Note the mismatch this exposes: `RotationLock` treats a lock older
  # than 10 minutes as stale and steals it, so a rotation running longer
  # than that is already unprotected regardless of this timeout. See
  # #1496 for the timeout and #1507 for that gap.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(60)

  # While the v5 rebuild is `on`, a rotation would re-encrypt payloads the
  # pass is rewriting: wait it out, writing nothing (Task 16.4).
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}, attempt: attempt})
      when is_binary(user_id) do
    if Engram.Rebuild.mode() == :on, do: {:snooze, 3600}, else: rotate(user_id, attempt)
  end

  # Tolerant fall-through for malformed args (T3.2-style guard).
  def perform(%Oban.Job{args: args}) do
    {:discard, {:invalid_args, Map.keys(args)}}
  end

  defp rotate(user_id, attempt) do
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

      # No Qdrant clause: the point sweeps run after the flip and never fail
      # the rotation. (A snooze here once claimed the retry "resumes
      # idempotently"; it does not. Once `sweep_notes` ran, the notes are
      # under this attempt's unsaved DEK and a retry mints another: #1507.)
      {:error, reason} ->
        {:error, reason}
    end
  end
end
