defmodule Mix.Tasks.Engram.ContentHashHmac do
  @shortdoc "Enqueue content_hash MD5→HMAC backfill jobs"

  @moduledoc """
  Phase A — enqueue content_hash MD5 → HMAC-SHA256 backfill jobs for every
  (user, vault) pair that still holds legacy MD5 hashes, via
  `Engram.ContentHash.Backfill.enqueue_all/0`.

  Thin wrapper only — `Mix.Task` is unavailable in a release, so the actual
  enqueue logic lives in `Engram.ContentHash.Backfill`, which release rpc calls
  directly instead of going through this task:

      docker exec engram-saas /app/bin/engram rpc 'Engram.ContentHash.Backfill.enqueue_all()'

  Local/dev use:

      mix engram.content_hash_hmac

  Idempotent: re-runs only enqueue pairs that still have legacy MD5 rows.
  """

  use Mix.Task

  alias Engram.ContentHash.Backfill

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    %{notes: note_count, attachments: att_count} = Backfill.enqueue_all()
    IO.puts("enqueued: #{note_count} note jobs + #{att_count} attachment jobs")
  end
end
