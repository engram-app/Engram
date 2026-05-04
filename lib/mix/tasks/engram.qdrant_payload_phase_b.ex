defmodule Mix.Tasks.Engram.QdrantPayloadPhaseB do
  @moduledoc """
  Enqueues `Engram.Workers.QdrantPayloadPhaseB` jobs for every (user, vault)
  combination that has at least one chunk row in Postgres — the universe of
  Qdrant points the worker needs to PATCH. Idempotent: rerunning is safe; the
  worker patches with identical payloads (no-op on Qdrant) and the cursor
  advances over note ids regardless.

  Run **after** Phase B.1 backfill is complete (worker reads `path_hmac` /
  `folder_hmac` / `tags_hmac` straight off the note row).

  Usage:

    # Local dev (mix available):
    mix engram.qdrant_payload_phase_b

    # Production (release — Mix not available, use rpc with inline body):
    docker exec engram-saas /app/bin/engram rpc "
    import Ecto.Query
    alias Engram.Notes.Chunk
    alias Engram.Repo
    alias Engram.Workers.QdrantPayloadPhaseB

    pairs = Repo.all(from(c in Chunk, group_by: [c.user_id, c.vault_id], select: {c.user_id, c.vault_id}), skip_tenant_check: true)

    for {uid, vid} <- pairs do
      %{\"user_id\" => uid, \"vault_id\" => vid, \"last_id\" => 0} |> QdrantPayloadPhaseB.new() |> Oban.insert!()
    end
    IO.puts(\"enqueued \#{length(pairs)}\")
    "
  """

  use Mix.Task

  import Ecto.Query

  alias Engram.Notes.Chunk
  alias Engram.Repo
  alias Engram.Workers.QdrantPayloadPhaseB

  @shortdoc "Enqueue Phase B Qdrant payload PATCH jobs"

  def run(_args) do
    Mix.Task.run("app.start")

    pairs = gather_pairs()

    IO.puts("Enqueueing Qdrant payload Phase B PATCH for #{length(pairs)} (user, vault) pairs")

    for {user_id, vault_id} <- pairs do
      %{"user_id" => user_id, "vault_id" => vault_id, "last_id" => 0}
      |> QdrantPayloadPhaseB.new()
      |> Oban.insert!()
    end

    IO.puts("Done. Watch oban_jobs queue=:crypto_backfill for progress.")
  end

  @doc """
  Returns deduplicated `{user_id, vault_id}` pairs derived from the chunks
  table. Pairs without any chunks (and therefore no Qdrant points) are
  skipped — there's nothing for the worker to PATCH.
  """
  def gather_pairs do
    Repo.all(
      from(c in Chunk,
        group_by: [c.user_id, c.vault_id],
        select: {c.user_id, c.vault_id}
      ),
      skip_tenant_check: true
    )
  end
end
