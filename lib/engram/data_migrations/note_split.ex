defmodule Engram.DataMigrations.NoteSplit do
  @moduledoc """
  Fills wave 3's narrow `notes` columns and `note_bodies` for rows written
  before the `notes_derive_core_keys` / `notes_sync_body` triggers existed
  (migration 20261021110200). Every later write fills them itself, from any
  release's code, so this only catches up.

  The work is the triggers' own: a pass touches `kind` (`SET kind = kind`),
  which both triggers list, so each row is derived by exactly the code that
  derives new writes. `seq` and `updated_at` are untouched: no sync feed or
  cache sees a change.

  A row needs work when its derived columns were never set (`is_folder` is
  NULL; the trigger always sets it) or it is a note with no body row.
  Discovery is one maintenance-pool query per batch on SaaS, a per-user loop
  on self-host (`TenantScan`).

  Readers keep using the old columns; nothing gates on this yet. Re-verifies
  daily, so a row a trigger somehow missed (a restore from an old dump) is
  caught.
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.Backfill.TenantScan
  alias Engram.Notes.Note
  alias Engram.Repo

  @batch 1_000
  # Rows per pass: a pass is one bounded slice; the next run takes the rest.
  @max_batches 50

  @impl true
  def name, do: "note_split"

  @impl true
  def version, do: 1

  @impl true
  def reverify?, do: true

  @impl true
  def run_pass do
    touched =
      case Repo.maintenance() do
        Repo ->
          TenantScan.user_ids()
          |> Enum.map(fn user_id ->
            batches(fn after_id ->
              Repo.with_tenant!(user_id, fn -> touch(Repo, needing(user_id, after_id)) end)
            end)
          end)
          |> Enum.sum()

        maintenance ->
          batches(fn after_id -> touch(maintenance, needing(nil, after_id)) end)
      end

    if touched == 0, do: :done, else: {:more, rows: touched}
  end

  # Runs `step` from an id keyset until a batch comes back short or the pass's
  # budget is spent, so each batch reads on from the last instead of rescanning
  # the rows already fixed.
  defp batches(step, after_id \\ nil, n \\ 0, rounds \\ 0)
  defp batches(_step, _after_id, n, @max_batches), do: n

  defp batches(step, after_id, n, rounds) do
    case step.(after_id) do
      ids when length(ids) < @batch -> n + length(ids)
      ids -> batches(step, Enum.max(ids), n + @batch, rounds + 1)
    end
  end

  # In id order with SKIP LOCKED: one batch locks up to 1,000 rows across
  # tenants, and a user's multi-row write (a folder rename, a batch push)
  # locks in its own order. A row a writer holds is skipped, not waited on;
  # that write fires the triggers itself, and a later pass takes any it left.
  defp needing(user_id, after_id) do
    q =
      from(n in "notes",
        as: :n,
        where:
          is_nil(field(n, :is_folder)) or
            (field(n, :kind) == "note" and
               not exists(
                 from(b in "note_bodies", where: b.note_id == parent_as(:n).id, select: 1)
               )),
        order_by: field(n, :id),
        select: field(n, :id),
        limit: @batch,
        lock: "FOR UPDATE SKIP LOCKED"
      )

    q = if after_id, do: where(q, [n], field(n, :id) > type(^after_id, Ecto.UUID)), else: q
    if user_id, do: where(q, [n], field(n, :user_id) == type(^user_id, Ecto.UUID)), else: q
  end

  # ONE statement: the ids subquery and the touch. Returns the touched ids;
  # lowercase uuid strings sort as their bytes do, so the max is the keyset.
  defp touch(repo, needing) do
    {_count, ids} =
      repo.update_all(
        from(n in Note,
          where: n.id in subquery(needing),
          update: [set: [kind: fragment("kind")]],
          select: n.id
        ),
        []
      )

    ids
  end
end
