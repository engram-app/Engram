defmodule Engram.Links.Backfill do
  @moduledoc """
  Enqueues the note-links backfill chain (`Engram.Workers.BackfillNoteLinks`,
  scopes `"note_hmacs"` -> `"attachment_hmacs"` -> `"links"`) for every
  (user, vault) pair that has notes or attachments.

  A plain function rather than a `Mix.Task` — `Mix.Task` is unavailable in a
  compiled release, so this is what `lib/mix/tasks/engram.backfill_note_links.ex`
  wraps, and what release rpc calls directly:

      docker exec engram-saas /app/bin/engram rpc 'Engram.Links.Backfill.enqueue_all()'

  `enqueue_missing/0` is the targeted variant the `NoteLinkHmacs` data
  migration runs hourly: only pairs with a row still lacking a
  `basename_hmac`.

  Idempotent: re-running just re-enqueues the chain for every pair again: the
  worker's own per-scope filters (`is_nil(basename_hmac)` for the hmac
  scopes, delete+insert for links) make a duplicate run a harmless no-op scan.
  """

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Backfill.TenantScan
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault
  alias Engram.Workers.BackfillNoteLinks

  @start_cursor "00000000-0000-0000-0000-000000000000"

  @doc "Enqueue the first scope (`\"note_hmacs\"`) for every (user, vault) pair. Returns the count."
  @spec enqueue_all() :: non_neg_integer()
  def enqueue_all do
    enqueue(MapSet.new(distinct_pairs(Note) ++ distinct_pairs(Attachment)))
  end

  @doc """
  Enqueue the chain only for (user, vault) pairs in a live vault holding a
  note or attachment with no `basename_hmac`: the rows the worker's hmac
  scopes stamp (it discards a deleted vault's jobs). Returns the count; zero
  means nothing the worker could fix is left.
  """
  @spec enqueue_missing() :: non_neg_integer()
  def enqueue_missing do
    note_gaps = from(n in Note, where: n.kind == "note")
    enqueue(MapSet.new(missing_pairs(note_gaps) ++ missing_pairs(Attachment)))
  end

  defp enqueue(pairs) do
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

  defp missing_pairs(queryable) do
    TenantScan.flat_map_users(fn user_id ->
      from(r in queryable,
        join: v in Vault,
        on: v.id == r.vault_id and is_nil(v.deleted_at),
        where: r.user_id == ^user_id,
        where: is_nil(r.basename_hmac) and not is_nil(r.path_ciphertext),
        distinct: true,
        select: r.vault_id
      )
      |> Repo.all()
      |> Enum.map(&{user_id, &1})
    end)
  end
end
