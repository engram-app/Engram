defmodule Engram.Workers.MigrateUserProvider do
  @moduledoc """
  Phase 3 — Oban worker that rewraps one user's `encrypted_dek` from the
  source provider (identified by blob tag) to `target_provider`.

  Args:

      %{"user_id" => integer, "target_provider" => "local" | "aws_kms"}

  Idempotent at two layers:

  1. Oban uniqueness on `[:user_id, :target_provider]` for in-flight
     states prevents duplicate jobs for the same target.
  2. `ProviderMigration.migrate_user/2` returns `:skipped` when the user
     is already at target — re-running stale jobs is a no-op.

  Production runs prefer this worker over the long-lived Mix task: jobs
  survive node restarts via Oban persistence, and the `:crypto_backfill`
  queue's concurrency=1 serializes against other crypto migrations
  (master rotation, AAD rebind, DEK rotation).
  """

  use Oban.Worker,
    queue: :crypto_backfill,
    max_attempts: 5,
    unique: [
      keys: [:user_id, :target_provider],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Engram.Crypto.ProviderMigration

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "target_provider" => target}})
      when is_integer(user_id) and target in ["local", "aws_kms"] do
    target_atom = String.to_existing_atom(target)

    case ProviderMigration.migrate_user(user_id, target_atom) do
      :ok -> :ok
      :skipped -> :ok
      {:error, {:not_found, _}} -> {:discard, :user_deleted}
      {:error, :no_dek} -> {:discard, :no_dek}
      {:error, :malformed_wrapped_blob} -> {:discard, :malformed_wrapped_blob}
      {:error, :unrecognised_blob} -> {:discard, :unrecognised_blob}
      {:error, %Ecto.Changeset{errors: errors}} -> {:discard, {:changeset_invalid, errors}}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{
        args: %{"user_id" => _user_id, "target_provider" => other}
      }) do
    {:discard, {:unknown_target, other}}
  end

  def perform(%Oban.Job{args: args}) do
    {:discard, {:invalid_args, Map.keys(args)}}
  end
end
