defmodule Mix.Tasks.Engram.RotateMasterKey do
  @shortdoc "Rewrap every user's encrypted_dek with the current master key"

  @moduledoc """
  T3.5.1 — Master-key rotation backfill (Mix entrypoint).

  Streams every user with `dek_version < target_version` and rewraps each
  one's `encrypted_dek` with the current master key
  (`ENCRYPTION_MASTER_KEY`). Idempotent — re-running with the same
  `--target-version` skips users already at target.

  ## Usage (dev / staging)

      mix engram.rotate_master_key --target-version 2

  ## Usage (production via release rpc)

      docker exec engram-saas /app/bin/engram rpc \\
        'Engram.Crypto.MasterRotation.rotate_all(2)'

  Production prefers the release-rpc form (no Mix in OTP releases) or
  enqueuing `Engram.Workers.RotateUserMasterKey` per user (cursor-driven
  variant). The Mix task is for short-lived local + staging runs.

  ## Pre-rotation checklist

  1. Set both env vars on the running app:

         ENCRYPTION_MASTER_KEY=<NEW>
         ENCRYPTION_MASTER_KEY_PREVIOUS=<OLD>

  2. Boot canary (`Engram.Crypto.BootCanary`) verifies NEW key can unwrap
     a synthetic record. Boot fails loudly if NEW is wrong.

  3. Run rotation. Telemetry `[:engram, :crypto, :rotate, :user]` reports
     per-user `:ok` / `:skipped` / `:failed`.

  4. Verify completion with `SELECT MIN(dek_version) FROM users` ≥ target.

  5. Drop `ENCRYPTION_MASTER_KEY_PREVIOUS` from env.
  """

  use Mix.Task

  alias Engram.Crypto.MasterRotation

  @switches [target_version: :integer, batch_size: :integer]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, switches: @switches)
    target = Keyword.fetch!(opts, :target_version)
    batch_size = Keyword.get(opts, :batch_size, 100)

    IO.puts("rotating users to dek_version #{target} (batch_size=#{batch_size})...")

    counts = MasterRotation.rotate_all(target, batch_size: batch_size)

    IO.puts(
      "rotation complete: ok=#{counts.ok} skipped=#{counts.skipped} failed=#{counts.failed}"
    )

    if counts.failed > 0 do
      IO.puts(:stderr, "ERROR: #{counts.failed} users failed rotation — inspect telemetry")
      System.halt(1)
    end
  end
end
