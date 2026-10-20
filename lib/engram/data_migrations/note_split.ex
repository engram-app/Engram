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
            batches(fn ->
              Repo.with_tenant!(user_id, fn -> touch(Repo, needing(user_id)) end)
            end)
          end)
          |> Enum.sum()

        maintenance ->
          batches(fn -> touch(maintenance, needing(nil)) end)
      end

    if touched == 0, do: :done, else: {:more, rows: touched}
  end

  # Runs `step` until a batch comes back short, or the pass's budget is spent.
  defp batches(step, n \\ 0, rounds \\ 0)
  defp batches(_step, n, @max_batches), do: n

  defp batches(step, n, rounds) do
    case step.() do
      count when count < @batch -> n + count
      count -> batches(step, n + count, rounds + 1)
    end
  end

  defp needing(user_id) do
    q =
      from(n in "notes",
        as: :n,
        where:
          is_nil(field(n, :is_folder)) or
            (field(n, :kind) == "note" and
               not exists(
                 from(b in "note_bodies", where: b.note_id == parent_as(:n).id, select: 1)
               )),
        select: field(n, :id),
        limit: @batch
      )

    if user_id, do: where(q, [n], field(n, :user_id) == type(^user_id, Ecto.UUID)), else: q
  end

  # ONE statement: the ids subquery and the touch, so a batch ships no ids.
  defp touch(repo, needing) do
    {count, _} =
      repo.update_all(
        from(n in Note,
          where: n.id in subquery(needing),
          update: [set: [kind: fragment("kind")]]
        ),
        []
      )

    count
  end
end
