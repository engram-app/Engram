defmodule Mix.Tasks.Engram.RotateUserDek do
  @moduledoc """
  T3.7 — operator entry point for per-user DEK rotation.

  > **WARNING: Local / staging only** — `Mix.Task` is unavailable in production
  > release containers. For production rotation use the Oban worker
  > (`Engram.Workers.RotateUserDek.new/1`) or release rpc
  > (`bin/engram rpc 'Engram.Crypto.UserDekRotation.rotate_user(<ID>)'`).

  ## Usage

      mix engram.rotate_user_dek --user-id 42

  Synchronous: blocks until the user's data is fully re-encrypted under
  a new DEK. The user is read+write locked for the duration; clients
  receive HTTP 503 + `Retry-After: 60`.

  The new dek_version is chosen internally (`current + 1`). Operators
  do not specify a target — re-running rotates again to a fresh
  version. See runbook in
  `docs/context/encryption-operations.md` § T3.7.4.

  ## Pre-flight checklist

  1. Confirm no other rotation is in flight:
       SELECT id FROM users WHERE dek_rotation_locked_at IS NOT NULL;

  2. Capture current dek_version (rollback reference):
       SELECT id, dek_version FROM users WHERE id = :user_id;

  3. Run the command. Watch telemetry
     `engram.crypto.rotate.dek.count` (`status=ok`/`failed`).

  ## Exit codes

  - `0` — rotation complete
  - `1` — rotation FAILED — investigate before retry
  - `2` — lock held by another rotation; retry or wait 10 min for stale-takeover
  - `3` — user not found
  - `4` — FATAL: user deleted during rotation; data state may be inconsistent — investigate before retry
  - `5` — FATAL: prior rotation crashed mid-attachment with non-null `dek_version_pending`; restore S3 blobs from versioning + clear pending state + clear lock manually before retry
  """

  use Mix.Task

  alias Engram.Crypto.UserDekRotation

  @shortdoc "Rotate one user's DEK, re-encrypting all their data under a fresh key"

  @switches [user_id: :integer]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, switches: @switches)
    user_id = Keyword.fetch!(opts, :user_id)

    IO.puts("rotating DEK for user_id=#{user_id}...")

    case UserDekRotation.rotate_user(user_id) do
      :ok ->
        IO.puts("rotation complete: user_id=#{user_id}")
        :ok

      {:error, :rotation_in_progress} ->
        IO.puts(:stderr, "ERROR: lock held by another rotation; retry or wait 10 min for stale-takeover")
        exit({:shutdown, 2})

      {:error, :not_found} ->
        IO.puts(:stderr, "ERROR: user not found user_id=#{user_id}")
        exit({:shutdown, 3})

      {:error, {:user_vanished_mid_rotation, _}} ->
        IO.puts(
          :stderr,
          "FATAL: user deleted during rotation; data state may be inconsistent — investigate before retry"
        )

        exit({:shutdown, 4})

      {:error, :half_state_pending} ->
        IO.puts(
          :stderr,
          "FATAL: prior rotation crashed mid-attachment with non-null dek_version_pending; " <>
            "restore S3 blobs from versioning + clear pending state + clear lock manually before retry"
        )

        exit({:shutdown, 5})

      {:error, reason} ->
        IO.puts(:stderr, "ERROR: rotation FAILED — investigate before retry reason=#{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
