defmodule Engram.Workers.RotationTextGuard do
  @moduledoc """
  The durable half of a DEK rotation's point-text sweep.

  Only the rotating process can rewrap point text: it alone holds the
  retired DEK, which is never persisted. So the flip commits this job with
  itself, scheduled past the sweep, and the process cancels it once its own
  sweep is done. If the node dies in between, this runs and checks every
  point of the user under the current DEK (`UserDekRotation.verify_point_text/1`):
  a note whose text no longer opens is rebuilt (unmetered maintenance), an
  orphan point is deleted. Nothing readable is touched, so a run that finds
  the sweep finished costs reads only.

  A Qdrant failure is a retry, never a whole-vault re-embed. A newer
  rotation (another `dek_version`) owns its own guard, so this one is a
  no-op.
  """
  use Oban.Worker,
    queue: :crdt_backfill,
    priority: 3,
    max_attempts: 10,
    unique: [
      keys: [:user_id, :dek_version],
      period: :infinity,
      states: [:available, :scheduled, :retryable]
    ]

  alias Engram.Accounts.User
  alias Engram.Crypto.{RotationGate, UserDekRotation}
  alias Engram.Repo

  # Past any sweep the rotating process could still be running: a ~150k
  # point user sweeps in minutes (`Qdrant.set_payloads/2`, review M3).
  # ponytail: a fixed delay; a guard that fires while a slower sweep is still
  # going rebuilds the notes it has not reached yet (cost, not data). Key it
  # off a heartbeat if vaults ever sweep for longer.
  @delay_seconds 3_600

  @doc "How long after the flip the guard runs (its `schedule_in`)."
  def delay_seconds, do: @delay_seconds

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "dek_version" => version}}) do
    case Repo.get(User, user_id) do
      %User{dek_version: ^version} = user ->
        case RotationGate.check_user(user) do
          :ok -> UserDekRotation.verify_point_text(user)
          {:error, :rotation_in_progress} -> {:snooze, 60}
        end

      _gone_or_rotated_again ->
        :ok
    end
  end
end
