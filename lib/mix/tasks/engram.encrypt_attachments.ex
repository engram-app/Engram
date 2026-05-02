defmodule Mix.Tasks.Engram.EncryptAttachments do
  @moduledoc """
  Enqueue `Engram.Workers.EncryptAttachments` jobs for every vault that
  still holds at least one legacy plaintext attachment
  (`encryption_version = 0`).

      mix engram.encrypt_attachments

  Idempotent: re-running after partial completion only enqueues vaults
  with remaining plaintext rows. Safe to schedule.
  """

  use Mix.Task

  alias Engram.Workers.EncryptAttachments

  @shortdoc "Enqueue attachment backfill for every vault with legacy plaintext rows"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    {:ok, count} = EncryptAttachments.enqueue_legacy_vaults()
    Mix.shell().info("Enqueued backfill for #{count} vault(s)")
  end
end
