defmodule Engram.ContentHash.Backfill do
  @moduledoc """
  Enqueues the content_hash MD5 → HMAC-SHA256 backfill
  (`Engram.Workers.BackfillContentHashHmac`, scopes `"notes"` and
  `"attachments"`) for every (user, vault) pair that still holds at least one
  legacy MD5 hash.

  A plain function rather than a `Mix.Task` — `Mix.Task` is unavailable in a
  compiled release, so this is what `lib/mix/tasks/engram.content_hash_hmac.ex`
  wraps, and what release rpc calls directly:

      docker exec engram-saas /app/bin/engram rpc 'Engram.ContentHash.Backfill.enqueue_all()'

  Matches `Engram.Links.Backfill`, which hit the same wall first.

  Idempotent: only pairs that still have `length(content_hash) = 32` rows are
  enqueued, and the worker applies the same filter per batch, so a re-run after
  a partial pass is a no-op scan.
  """

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.BackfillContentHashHmac

  require Logger

  @start_cursor "00000000-0000-0000-0000-000000000000"

  @doc """
  Enqueue one job per (user, vault, scope) tuple that still has legacy MD5
  rows. Returns the per-scope job counts.
  """
  @spec enqueue_all() :: %{notes: non_neg_integer(), attachments: non_neg_integer()}
  def enqueue_all do
    %{
      notes: enqueue_scope(Note, "notes"),
      attachments: enqueue_scope(Attachment, "attachments")
    }
  end

  # One `insert_all` per scope rather than a per-pair `Oban.insert/1` loop: the
  # loop's `{:ok, _job} =` match turned any single insert error into a
  # MatchError partway through, leaving an unknown prefix of jobs enqueued and
  # no count to reason about. A scope now lands whole or not at all.
  #
  # Safe here specifically because BackfillContentHashHmac carries NO `unique`
  # option (see the #1230 comment on the worker) — `insert_all` bypasses
  # unique-job resolution, which would silently drop jobs on a worker that had
  # one.
  defp enqueue_scope(schema, scope) do
    pairs = legacy_pairs(schema)

    # Logged before the insert so a failure mid-run still tells the operator
    # how much each scope needed — the pair counts the mix task used to print.
    Logger.info("content_hash backfill: #{length(pairs)} #{scope} pair(s) with legacy MD5 hashes")

    pairs
    |> Enum.map(fn {user_id, vault_id} ->
      BackfillContentHashHmac.new(%{
        "user_id" => user_id,
        "vault_id" => vault_id,
        "cursor" => @start_cursor,
        "scope" => scope
      })
    end)
    |> Oban.insert_all()
    |> length()
  end

  defp legacy_pairs(schema) do
    from(r in schema,
      where: not is_nil(r.content_hash),
      where: fragment("length(?) = 32", r.content_hash),
      group_by: [r.user_id, r.vault_id],
      select: {r.user_id, r.vault_id}
    )
    |> Repo.all(skip_tenant_check: true)
  end
end
