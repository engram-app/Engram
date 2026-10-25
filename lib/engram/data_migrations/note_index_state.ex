defmodule Engram.DataMigrations.NoteIndexState do
  @moduledoc """
  Fills `note_index_state` for notes written before the
  `notes_sync_index_state` trigger existed (migration 20261025000000). Every
  later write fills it itself, from any release's code, so this only
  catches up.

  The work is the trigger's own SQL function (`note_index_state_sync`), in
  fill-only mode: a row the trigger already wrote is newer than this pass's
  snapshot and is never replaced. It writes no `notes` row, so the notes
  table (24 indexes, measured 2026-10-24) takes no extra versions.

  Then the chunk counters (`points`, `len_rows`, `len_sum`): every note
  whose counters differ from its `chunks` rows is re-counted under its
  `notes` row lock (`FOR UPDATE SKIP LOCKED`, the lock `commit_index` holds
  while it writes chunks), so the count cannot race a pass on that note.
  This is both the backfill and the self-heal: done (`counted?/0`) gates
  the vault and user sums, and the daily re-verify re-counts whatever a
  previous-release writer (a rolling deploy, a rollback) left behind.

  Discovery is one maintenance-pool query per batch on SaaS, a per-user
  loop on self-host (`TenantScan`), like `NoteSplit`. The embed columns are
  not read yet.
  """
  @behaviour Engram.DataMigration

  alias Engram.Backfill.TenantScan
  alias Engram.Indexing.ChunkRows
  alias Engram.Repo

  @batch 1_000
  @max_batches 50

  @impl true
  def name, do: "note_index_state"

  @impl true
  def version, do: 1

  @impl true
  def reverify?, do: true

  @impl true
  def run_pass, do: run_pass([])

  @doc """
  True once every note's chunk counters were counted: the vault and user
  sums over `note_index_state` may replace the `count(*)` / `avg` over
  `chunks`.
  """
  @spec counted?() :: boolean()
  def counted?, do: Engram.DataMigrations.done?(name(), version())

  @doc false
  # `batch:` overrides the batch size (tests page over a few rows).
  def run_pass(opts) do
    batch = Keyword.get(opts, :batch, @batch)

    {fixed, left?} =
      case Repo.maintenance() do
        Repo ->
          users = TenantScan.user_ids()

          fixed =
            users
            |> Enum.map(fn user_id ->
              batches(batch, fn after_id ->
                Repo.with_tenant!(user_id, fn -> fill(Repo, user_id, after_id, batch) end)
              end) +
                batches(batch, fn after_id ->
                  Repo.with_tenant!(user_id, fn -> recount(Repo, user_id, after_id, batch) end)
                end)
            end)
            |> Enum.sum()

          {fixed,
           fn ->
             Enum.any?(users, fn user_id ->
               Repo.with_tenant!(user_id, fn -> left?(Repo, user_id) end)
             end)
           end}

        maintenance ->
          {batches(batch, &fill(maintenance, nil, &1, batch)) +
             batches(batch, fn after_id ->
               {:ok, ids} =
                 maintenance.transaction(fn -> recount(maintenance, nil, after_id, batch) end)

               ids
             end), fn -> left?(maintenance, nil) end}
      end

    cond do
      fixed > 0 -> {:more, rows: fixed}
      left?.() -> {:more, rows: 0}
      true -> :done
    end
  end

  defp batches(batch, step, after_id \\ nil, n \\ 0, rounds \\ 0)
  defp batches(_batch, _step, _after_id, n, @max_batches), do: n

  defp batches(batch, step, after_id, n, rounds) do
    case step.(after_id) do
      ids when length(ids) < batch -> n + length(ids)
      ids -> batches(batch, step, Enum.max(ids), n + length(ids), rounds + 1)
    end
  end

  @missing """
  n.kind = 'note'
    AND ($1::uuid IS NULL OR n.user_id = $1::uuid)
    AND NOT EXISTS (SELECT 1 FROM note_index_state s WHERE s.note_id = n.id)
  """

  # Returns the filled ids (lowercase uuid strings sort as their bytes, so
  # the max is the keyset).
  defp fill(repo, user_id, after_id, batch) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT n.id::text, note_index_state_sync(n, false) FROM notes n
        WHERE #{@missing} AND ($2::uuid IS NULL OR n.id > $2::uuid)
        ORDER BY n.id LIMIT $3
        """,
        [dump(user_id), dump(after_id), batch]
      )

    Enum.map(rows, &hd/1)
  end

  # Notes whose counters differ from their chunk rows, in id order: one
  # index probe of `chunks (note_id, position)` per note.
  @drifted """
  n.kind = 'note'
    AND ($1::uuid IS NULL OR n.user_id = $1::uuid)
    AND ROW(s.points, s.len_rows, s.len_sum) IS DISTINCT FROM (
      SELECT ROW(count(*)::int, count(c.token_count)::int, coalesce(sum(c.token_count), 0)::bigint)
      FROM chunks c WHERE c.note_id = n.id)
  """

  # Inside a transaction: locks the drifted notes of this batch (skipping
  # any a writer holds; a later pass takes them), then counts them in a new
  # statement, so the count sees every chunk write that committed before
  # the lock. Returns the scanned ids (the keyset); `batches/5` stops on a
  # short page.
  defp recount(repo, user_id, after_id, batch) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT n.id::text FROM notes n JOIN note_index_state s ON s.note_id = n.id
        WHERE #{@drifted} AND ($2::uuid IS NULL OR n.id > $2::uuid)
        ORDER BY n.id LIMIT $3
        """,
        [dump(user_id), dump(after_id), batch]
      )

    ids = Enum.map(rows, &hd/1)

    locked = ChunkRows.lock_notes!(ids, repo: repo, skip_locked: true)
    _ = ChunkRows.recount!(locked, repo)
    ids
  end

  # Any note still missing its row or with drifted counters, locked or not.
  defp left?(repo, user_id) do
    %{rows: [[left]]} =
      repo.query!(
        """
        SELECT EXISTS (SELECT 1 FROM notes n WHERE #{@missing})
          OR EXISTS (SELECT 1 FROM notes n JOIN note_index_state s ON s.note_id = n.id
                     WHERE #{@drifted})
        """,
        [dump(user_id)]
      )

    left
  end

  defp dump(nil), do: nil
  defp dump(id), do: Ecto.UUID.dump!(id)
end
