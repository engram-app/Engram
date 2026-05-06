defmodule Mix.Tasks.Engram.ContentHashHmac do
  @moduledoc """
  Phase A — enqueue content_hash MD5 → HMAC-SHA256 backfill jobs.

  Walks `notes` and `attachments`, gathers every (user_id, vault_id) pair
  that has at least one row with a legacy MD5 (`length(content_hash) = 32`)
  hash, and enqueues one `Engram.Workers.BackfillContentHashHmac` job per
  (pair, scope) tuple. The worker batches and self-re-enqueues until each
  vault's stragglers are exhausted.

  Run on prod via release rpc once the new code is deployed:

      docker exec engram-saas /app/bin/engram rpc 'Mix.Tasks.Engram.ContentHashHmac.run([])'

  Idempotent: re-runs only enqueue pairs that still have legacy MD5 rows.
  """

  use Mix.Task

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.BackfillContentHashHmac

  @shortdoc "Enqueue content_hash MD5→HMAC backfill jobs"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    note_pairs = gather_pairs(Note)
    att_pairs = gather_pairs(Attachment)

    IO.puts("notes pairs needing backfill: #{length(note_pairs)}")
    IO.puts("attachments pairs needing backfill: #{length(att_pairs)}")

    note_count =
      Enum.reduce(note_pairs, 0, fn {user_id, vault_id}, acc ->
        enqueue!(user_id, vault_id, "notes")
        acc + 1
      end)

    att_count =
      Enum.reduce(att_pairs, 0, fn {user_id, vault_id}, acc ->
        enqueue!(user_id, vault_id, "attachments")
        acc + 1
      end)

    IO.puts("enqueued: #{note_count} note jobs + #{att_count} attachment jobs")
  end

  defp gather_pairs(schema) do
    from(r in schema,
      where: not is_nil(r.content_hash),
      where: fragment("length(?) = 32", r.content_hash),
      group_by: [r.user_id, r.vault_id],
      select: {r.user_id, r.vault_id}
    )
    |> Repo.all(skip_tenant_check: true)
  end

  defp enqueue!(user_id, vault_id, scope) do
    {:ok, _job} =
      BackfillContentHashHmac.new(%{
        "user_id" => user_id,
        "vault_id" => vault_id,
        "cursor" => 0,
        "scope" => scope
      })
      |> Oban.insert()
  end
end
