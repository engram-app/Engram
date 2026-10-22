defmodule Engram.Vector.PointIds do
  @moduledoc """
  The two questions every Postgres-vs-Qdrant point reconciliation asks,
  answered once: which of these ids does a `chunks.qdrant_point_id` name
  (`known/1`), and which of them does Qdrant hold (`present/2`). Plus the
  keyset page of live chunk rows both directions walk (`chunk_page/3`).

  Used by `Engram.Workers.OrphanSweep` (the daily sweep, against the active
  cluster) and `Engram.Vector.ClusterDiff` (old vs v2, against the cluster
  pinned with `Qdrant.with_cluster/2`).

  The Postgres reads run on `Repo.maintenance()`: these are cross-tenant
  reconciliations and RLS would hide exactly the rows that prove a point is
  live (engram-app/Engram#1746, see `OrphanSweep.maintenance_repo/0`). The
  `Repo.cross_tenant/1` wrapper is a no-op on the maintenance pool and
  load-bearing on the fallback `Repo`.
  """

  import Ecto.Query

  alias Engram.Notes.Chunk
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault
  alias Engram.Vector.Qdrant

  # Bind parameters per query, against Postgres' 65,535 cap.
  @id_query_batch 5_000

  @doc """
  The ids among `ids` that some chunk row names. Indexed lookup on
  `chunks.qdrant_point_id`, bounded by the caller's list, never a
  whole-table read.

  Chunked: one bind parameter per id against Postgres' 65,535 statement cap.
  A page is 4,096 and a candidate list can reach its cap plus a page, so
  neither caller is close today, but both are constants someone will raise,
  and the failure mode is the query raising mid-walk.
  """
  @spec known([String.t()]) :: MapSet.t(String.t())
  def known(ids) do
    repo = Repo.maintenance()

    ids
    |> cast_uuids()
    |> Enum.chunk_every(@id_query_batch)
    |> Enum.reduce(MapSet.new(), fn batch, acc ->
      Repo.cross_tenant(fn ->
        Chunk
        |> where([c], c.qdrant_point_id in ^batch)
        |> select([c], c.qdrant_point_id)
        |> repo.all()
        |> Enum.reject(&is_nil/1)
        |> Enum.into(acc)
      end)
    end)
  end

  @doc """
  Up to `limit` chunk rows after `after_id` (keyset on `chunks.id`), as
  `{chunk_id, note_id, point_id, user_id}`. `user_ids: [...]` restricts the
  walk to those owners.

  Live notes in live vaults only. A soft-deleted note's points are removed on
  delete, so its rows would read as stranded and get flagged for a rebuild
  that then has nothing to rebuild.

  The VAULT check is load-bearing for a different reason: `ReconcileEmbeddings`
  joins vaults on `is_nil(deleted_at)`, so a note in a soft-deleted vault can
  never be rebuilt. Flagging one means re-nulling and re-warning on every tick
  forever, while inflating the runaway ratio, and `CleanupVault` purges
  Qdrant points BEFORE its DB transaction, so a restore leaves exactly this
  shape: live rows in a soft-deleted vault whose points are already gone.
  """
  @spec chunk_page(Ecto.UUID.t() | nil, pos_integer(), keyword()) :: [
          {Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()}
        ]
  def chunk_page(after_id, limit, opts \\ []) do
    repo = Repo.maintenance()
    user_ids = Keyword.get(opts, :user_ids)

    Repo.cross_tenant(fn ->
      Chunk
      |> join(:inner, [c], n in Note, on: n.id == c.note_id)
      |> join(:inner, [c, n], v in Vault, on: v.id == n.vault_id)
      |> where([c, n, v], is_nil(n.deleted_at) and is_nil(v.deleted_at))
      |> where([c], not is_nil(c.qdrant_point_id))
      |> then(fn q -> if after_id, do: where(q, [c], c.id > ^after_id), else: q end)
      |> then(fn q -> if user_ids, do: where(q, [c], c.user_id in ^user_ids), else: q end)
      |> order_by([c], asc: c.id)
      |> limit(^limit)
      |> select([c], {c.id, c.note_id, c.qdrant_point_id, c.user_id})
      |> repo.all()
    end)
  end

  @doc """
  Which of these ids does Qdrant (the active or pinned cluster) hold?
  `has_id` against the scroll endpoint, `batch` ids per request.

  Batched even when the caller already pages, because a confirm pass hands in
  a whole candidate list at once. `has_id` carries every id in the REQUEST
  body, so an unbounded call is a multi-megabyte POST, and the answer decides
  whether to null hashes: a truncated response reads as "these ids are
  missing" and re-embeds notes whose points are fine.
  """
  @spec present([String.t()], pos_integer()) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def present([], _batch), do: {:ok, MapSet.new()}

  def present(point_ids, batch) do
    point_ids
    |> Enum.uniq()
    |> Enum.chunk_every(batch)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn ids, {:ok, acc} ->
      case scroll_ids(ids, nil, MapSet.new()) do
        {:ok, found} -> {:cont, {:ok, MapSet.union(acc, found)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Follows `next_page_offset` rather than trusting one response to carry every
  # match. A `limit` is not a guarantee.
  defp scroll_ids(batch, offset, acc) do
    opts = [
      filter: %{must: [%{has_id: batch}]},
      limit: length(batch),
      with_payload: false,
      with_vector: false
    ]

    opts = if offset, do: Keyword.put(opts, :offset, offset), else: opts

    case Qdrant.scroll(opts) do
      {:ok, %{points: points, next_page_offset: next}} ->
        acc =
          points
          |> Enum.map(& &1["id"])
          |> Enum.filter(&is_binary/1)
          |> Enum.into(acc)

        if next, do: scroll_ids(batch, next, acc), else: {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Qdrant ids are whatever the collection holds; ours are uuids, but one
  # malformed value would raise `Ecto.Query.CastError` out of a
  # `max_attempts: 1` worker and kill the pass mid-walk. Same guard as
  # `Notes.display_fields_by_qdrant_points/2` on the identical query.
  defp cast_uuids(ids) do
    Enum.flat_map(ids, fn id ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> [uuid]
        :error -> []
      end
    end)
  end
end
