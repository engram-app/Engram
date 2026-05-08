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
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Engram.Crypto.MasterRotation

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "target_version" => target_version}})
      when is_integer(user_id) and is_integer(target_version) and target_version >= 1 do
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
