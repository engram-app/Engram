defmodule Engram.Workers.RotateUserMasterKey do
  @moduledoc """
  T3.5.2 — Cursor-driven Oban worker variant of master-key rotation.

  One job per user. Args:

      %{"user_id" => integer, "target_version" => pos_integer}

  Idempotent at two layers:

  1. Oban uniqueness on `[:user_id, :target_version]` for in-flight states
     prevents duplicate jobs for the same target.
  2. `MasterRotation.rotate_user/2` returns `:skipped` when `dek_version`
     is already ≥ target — re-running stale jobs after a rotation completes
     is a no-op.

  Production runs prefer this worker over the long-lived Mix task: jobs
  survive node restarts via Oban persistence, and the `:crypto_backfill`
  queue's concurrency=1 setting serializes against other crypto migrations.
  """

  use Oban.Worker,
    queue: :crypto_backfill,
    max_attempts: 5,
    unique: [
      keys: [:user_id, :target_version],
      states: :incomplete
    ]

  alias Engram.Crypto.MasterRotation

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

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "target_version" => target_version}})
      when is_binary(user_id) and is_integer(target_version) and target_version >= 1 do
    case MasterRotation.rotate_user(user_id, target_version) do
      :ok -> :ok
      :skipped -> :ok
      {:error, {:not_found, _}} -> {:discard, :user_deleted}
      {:error, :no_dek} -> {:discard, :no_dek}
      # Validation errors are deterministic — retrying 5 times wastes
      # Oban capacity. Discard with the changeset's error map for triage.
      {:error, %Ecto.Changeset{errors: errors}} -> {:discard, {:changeset_invalid, errors}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Tolerant fall-through for legacy / malformed args (T3.2-style guard).
  def perform(%Oban.Job{args: args}) do
    {:discard, {:invalid_args, Map.keys(args)}}
  end
end
