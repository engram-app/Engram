defmodule Mix.Tasks.Engram.RebindAad do
  @shortdoc "Rebind every user's notes/vaults to row-id-bound AAD (T3.6)"

  @moduledoc """
  T3.6.3 — AAD-rebind backfill (Mix entrypoint).

  Walks every user with at least one legacy-encrypted row
  (`dek_version=1`) and re-encrypts notes / vaults under the row-id-bound
  AAD, stamping `dek_version=2` on each. Also upgrades each user's
  `encrypted_dek` wrap format from v1 (or pre-T3.4 legacy) to v2
  (AAD-bound, `"dek:v1:<user_id>"`).

  Idempotent — already-rebound users return `:skipped` and are skipped at
  perform-time. Per-user transaction with `SELECT ... FOR UPDATE`.

  ## Usage

      mix engram.rebind_aad
      mix engram.rebind_aad --batch-size 50

  ## Production via release rpc

      docker exec engram-saas /app/bin/engram rpc \\
        'Engram.Crypto.AadRebind.rebind_all()'

  Telemetry: `[:engram, :crypto, :aad_rebind, :user]` per user with
  `:ok | :skipped | :failed` status.

  ## Attachments

  This task DOES NOT rebind attachment ciphertext. Attachment content
  lives in S3-compatible object storage; rebinding `path_ciphertext`
  alone would mismatch the stamped `dek_version` against the S3 blob's
  legacy AAD on the next read. Attachments converge naturally on every
  re-upload (`Attachments.upsert_attachment/3` writes v2 AAD-bound).
  """

  use Mix.Task

  alias Engram.Crypto.AadRebind

  @switches [batch_size: :integer]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, switches: @switches)
    batch_size = Keyword.get(opts, :batch_size, 100)

    IO.puts("rebinding users to AAD-bound encryption (batch_size=#{batch_size})...")

    counts = AadRebind.rebind_all(batch_size: batch_size)

    IO.puts("rebind complete: ok=#{counts.ok} skipped=#{counts.skipped} failed=#{counts.failed}")

    if counts.failed > 0 do
      IO.puts(:stderr, "ERROR: #{counts.failed} users failed rebind — inspect telemetry")
      System.halt(1)
    end
  end
end
