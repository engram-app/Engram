defmodule Mix.Tasks.Engram.MigrateProvider do
  @shortdoc "Rewrap user encrypted_dek between KeyProviders (Local↔AwsKms)"

  @moduledoc """
  Phase 3 — Per-user `KeyProvider` migration entrypoint.

  ## Usage

      # Sync drain (dev / staging) — blocks until done:
      mix engram.migrate_provider --target aws_kms

      # Production: Oban enqueue (jobs survive node restart):
      mix engram.migrate_provider --target aws_kms --enqueue

      # Reverse rollback (KMS → Local):
      mix engram.migrate_provider --target local --enqueue

      # Provider count breakdown:
      mix engram.migrate_provider --status

  ## Exit codes

  - `0` — clean (all users at target, or `--status` ran successfully).
  - `1` — partial: at least one per-user failure (telemetry has details).
  - `2` — misconfig (unknown `--target`, missing required arg).

  ## Pre-cutover checklist

  1. Set Fly secrets: `KEY_PROVIDER=aws_kms`, `AWS_KMS_KEY_ID`,
     `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`.
  2. Deploy. `BootCanaryGuard.AwsKms.boot_check/0` verifies CMK reachable.
  3. Run `mix engram.migrate_provider --target aws_kms --enqueue` (or
     release-rpc the underlying API: `Engram.Crypto.ProviderMigration.enqueue_all(:aws_kms)`).
  4. Monitor `[:engram, :crypto, :migrate_provider, :user]` telemetry +
     `mix engram.migrate_provider --status` until `local` count = 0.
  """

  use Mix.Task

  alias Engram.Crypto.ProviderMigration

  @switches [target: :string, enqueue: :boolean, status: :boolean, batch_size: :integer]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    cond do
      opts[:status] ->
        print_status()
        :ok

      is_nil(opts[:target]) ->
        IO.puts(
          :stderr,
          "ERROR: --target is required (one of: aws_kms, local). Or pass --status."
        )

        exit({:shutdown, 2})

      true ->
        case target_atom(opts[:target]) do
          {:ok, target_atom} ->
            batch_size = Keyword.get(opts, :batch_size, 100)

            if opts[:enqueue] do
              run_enqueue(target_atom, batch_size)
            else
              run_drain(target_atom, batch_size)
            end

          :error ->
            IO.puts(
              :stderr,
              "ERROR: unknown --target #{inspect(opts[:target])}; expected aws_kms | local"
            )

            exit({:shutdown, 2})
        end
    end
  end

  defp target_atom("aws_kms"), do: {:ok, :aws_kms}
  defp target_atom("local"), do: {:ok, :local}
  defp target_atom(_), do: :error

  defp run_drain(target_atom, batch_size) do
    IO.puts("draining users → #{target_atom} (batch_size=#{batch_size})...")

    counts = ProviderMigration.migrate_all(target_atom, batch_size: batch_size)

    IO.puts(
      "migration complete: ok=#{counts.ok} skipped=#{counts.skipped} failed=#{counts.failed}"
    )

    if counts.failed > 0 do
      IO.puts(:stderr, "ERROR: #{counts.failed} users failed migration — inspect telemetry")
      exit({:shutdown, 1})
    end
  end

  defp run_enqueue(target_atom, batch_size) do
    IO.puts("enqueueing users → #{target_atom} (batch_size=#{batch_size})...")

    %{enqueued: n} = ProviderMigration.enqueue_all(target_atom, batch_size: batch_size)

    IO.puts("enqueued #{n} MigrateUserProvider jobs on :crypto_backfill")
  end

  defp print_status do
    counts = ProviderMigration.status_counts()
    IO.puts("local=#{counts.local} aws_kms=#{counts.aws_kms} total=#{counts.total}")
  end
end
