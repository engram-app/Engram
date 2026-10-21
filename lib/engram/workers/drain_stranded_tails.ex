defmodule Engram.Workers.DrainStrandedTails do
  @moduledoc """
  Cron: fold CRDT tails nothing else will fold.

  A `crdt_update_log` row is folded into the note's snapshot only by that
  note's next checkpoint: a room's tick or unbind, or a `CheckpointNote` job.
  A room that dies without unbind (OOM kill, node loss) leaves its rows, and
  if the note is never opened again they stay forever, replayed by every
  roomless read. This sweep enqueues a `CheckpointNote` for every live note
  with a tail row older than `@stale_minutes` and no live room (a live room
  owns its tail and checkpoints it itself). `CheckpointNote` is unique per
  note, so a tick never stacks a second job on a waiting one.

  Self-healing with no operator step, on self-host too: discovery is one
  maintenance-pool query on SaaS and a per-tenant loop elsewhere
  (`TenantScan.all/1`). The log is pruned at every checkpoint, so the scan is
  over a small table.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 600, states: :incomplete]

  import Ecto.Query

  alias Engram.Backfill.TenantScan
  alias Engram.Notes.{CrdtRegistry, CrdtUpdateLog, Note}
  alias Engram.Workers.CheckpointNote

  # Well past a room's idle drain (5 min) and its unbind checkpoint, so a row
  # this old has no checkpoint coming.
  @stale_minutes 30
  # Notes per page; a run reads every page.
  @batch 500

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    batch = Map.get(args, "batch", @batch)
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_minutes * 60, :second)

    from(l in CrdtUpdateLog,
      join: n in Note,
      on: n.id == l.note_id and is_nil(n.deleted_at) and n.kind == "note",
      where: l.inserted_at < ^cutoff,
      distinct: true,
      select: %{user_id: l.user_id, vault_id: l.vault_id, note_id: l.note_id}
    )
    |> TenantScan.all(&pages(&1, &2, batch, nil))
    |> Enum.reject(&CrdtRegistry.lookup(&1.note_id))
    |> Enum.each(fn args -> {:ok, _} = Oban.insert(CheckpointNote.new(args)) end)

    :ok
  end

  # Keyset pages by note_id, so notes that keep their tail (a live room, a
  # checkpoint that skips) cannot hold the first page on every tick and
  # starve the rest.
  defp pages(repo, query, batch, after_id) do
    page =
      query
      |> then(&if after_id, do: where(&1, [l], l.note_id > ^after_id), else: &1)
      |> order_by([l], l.note_id)
      |> limit(^batch)
      |> repo.all()

    if length(page) < batch,
      do: page,
      else: page ++ pages(repo, query, batch, List.last(page).note_id)
  end
end
