defmodule Engram.Links.Backfill do
  @moduledoc """
  Enqueues the note-links backfill chain (`Engram.Workers.BackfillNoteLinks`,
  scopes `"note_hmacs"` -> `"attachment_hmacs"` -> `"links"`) for every
  (user, vault) pair that has notes or attachments.

  A plain function rather than a `Mix.Task` — `Mix.Task` is unavailable in a
  compiled release, so this is what `lib/mix/tasks/engram.backfill_note_links.ex`
  wraps, and what release rpc calls directly:

      docker exec engram-saas /app/bin/engram rpc 'Engram.Links.Backfill.enqueue_all()'

  Idempotent: re-running just re-enqueues the chain for every pair again: the
  worker's own per-scope filters (`is_nil(basename_hmac)` for the hmac
  scopes, delete+insert for links) make a duplicate run a harmless no-op scan.
  """

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Backfill.TenantScan
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.BackfillNoteLinks

  @start_cursor "00000000-0000-0000-0000-000000000000"

  @doc "Enqueue the first scope (`\"note_hmacs\"`) for every (user, vault) pair. Returns the count."
  @spec enqueue_all() :: non_neg_integer()
  def enqueue_all do
    pairs = MapSet.new(distinct_pairs(Note) ++ distinct_pairs(Attachment))

    Enum.each(pairs, fn {user_id, vault_id} ->
      %{
        "user_id" => user_id,
        "vault_id" => vault_id,
        "cursor" => @start_cursor,
        "scope" => "note_hmacs"
      }
      |> BackfillNoteLinks.new()
      |> Oban.insert()
    end)

    MapSet.size(pairs)
  end

  # Per-user inside each tenant's RLS context, NOT one cross-tenant query with
  # `skip_tenant_check: true` — that reads zero rows on prod and enqueues
  # nothing while reporting success (#1349). See Engram.Backfill.TenantScan.
  defp distinct_pairs(schema) do
    TenantScan.flat_map_users(fn user_id ->
      from(r in schema, where: r.user_id == ^user_id, distinct: true, select: r.vault_id)
      |> Repo.all()
      |> Enum.map(&{user_id, &1})
    end)
  end
end
