defmodule Mix.Tasks.Engram.BackfillNoteLinks do
  @shortdoc "Enqueue the note-links backfill chain (hmacs + edges)"

  @moduledoc """
  Enqueues `Engram.Workers.BackfillNoteLinks` (scopes `"note_hmacs"` ->
  `"attachment_hmacs"` -> `"links"`) for every (user, vault) pair, via
  `Engram.Links.Backfill.enqueue_all/0`.

  Thin wrapper only — `Mix.Task` is unavailable in a release, so the actual
  enqueue logic lives in `Engram.Links.Backfill`, which release rpc calls
  directly instead of going through this task:

      docker exec engram-saas /app/bin/engram rpc 'Engram.Links.Backfill.enqueue_all()'

  Local/dev use:

      mix engram.backfill_note_links

  Idempotent: re-running just re-enqueues the chain; the worker's own
  per-scope filters make repeat runs harmless no-op scans.
  """

  use Mix.Task

  alias Engram.Links.Backfill

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    count = Backfill.enqueue_all()
    IO.puts("enqueued note-links backfill chain for #{count} (user, vault) pair(s)")
  end
end
