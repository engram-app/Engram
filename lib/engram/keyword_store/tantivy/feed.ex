defmodule Engram.KeywordStore.Tantivy.Feed do
  @moduledoc """
  Writes `keyword_feed` (the transactional outbox kwsearch reads) and the
  durable deletion log `keyword_deletions`. Row shapes and op codes are the
  kwfeed contract (`native/kwfeed/src/lib.rs`); kwsearch applies them by
  `(xid, seq)`, so every op is idempotent and every note op names its stamp.

  Every write runs in `Repo.with_tenant/2` for the row's user, so the tenant
  policy's WITH CHECK refuses a row naming another user (security F7), and
  every row, deletes included, carries its user: kwsearch scopes each delete
  by it too.

  Note-scoped ops lock the note row and take a stamp from
  `keyword_stamp_seq` under that lock, so a note's stamps rise in commit
  order: a later pass waits for the earlier one's commit before it stamps.
  Every note-scoped transaction writes `delete_note_except(keep)` FIRST, keep
  being the note's full point set (roadmap P2 task 4a); a pass applied out of
  xid order is resolved against the newer pass's set.
  """

  import Ecto.Query

  alias Engram.Indexing.ChunkRows
  alias Engram.KeywordStore.Tantivy.DeletionRow
  alias Engram.KeywordStore.Tantivy.FeedRow
  alias Engram.Notes.Chunk
  alias Engram.Repo

  # kwfeed op codes.
  @upsert 1
  @delete_points 2
  @delete_note 3
  @delete_vault 4
  @delete_user 5
  @delete_note_except 6

  # The live index generation (1x chunks). P3 builds a second beside it.
  @index_set 1

  @doc false
  def ops,
    do: %{
      upsert: @upsert,
      delete_points: @delete_points,
      delete_note: @delete_note,
      delete_vault: @delete_vault,
      delete_user: @delete_user,
      delete_note_except: @delete_note_except
    }

  @doc """
  One note-scoped op set: `delete_note_except(keep)` then an upsert per
  `{point_id, terms}`. Joins the caller's transaction for the same tenant
  (the index pass calls it inside its chunk-row transaction).
  """
  @spec note_pass(map(), [String.t()], [{String.t(), binary()}]) :: :ok
  def note_pass(scope, keep, upserts) do
    in_tenant(scope.user_id, fn ->
      stamp = lock_and_stamp(scope.note_id)
      base = note_row(scope, stamp)

      rows = [
        Map.merge(base, %{op: @delete_note_except, keep: Enum.map(keep, &uuid/1)})
        | for(
            {id, terms} <- upserts,
            do: Map.merge(base, %{op: @upsert, point_id: uuid(id), terms: terms})
          )
      ]

      insert_feed(rows)
    end)
  end

  @doc "The note's whole index goes (trash, hard delete): feed row and deletion log."
  @spec delete_note(map()) :: :ok
  def delete_note(scope) do
    in_tenant(scope.user_id, fn ->
      stamp = lock_and_stamp(scope.note_id)
      insert_feed([Map.put(note_row(scope, stamp), :op, @delete_note)])
      log_deletion(scope.user_id, @delete_note, scope.vault_id, scope.note_id)
    end)
  end

  @doc """
  Bare point deletes (no note known: a path-hmac or DEK orphan delete). Each
  row is scoped to `user_id`; kwsearch deletes the point only within it.
  """
  @spec delete_points(String.t(), [String.t()]) :: :ok
  def delete_points(user_id, point_ids) do
    in_tenant(user_id, fn ->
      point_ids
      |> Enum.map(
        &%{user_id: uuid(user_id), index_set: @index_set, op: @delete_points, point_id: uuid(&1)}
      )
      |> insert_feed()
    end)
  end

  @spec delete_vault(String.t(), String.t()) :: :ok
  def delete_vault(user_id, vault_id) do
    in_tenant(user_id, fn ->
      insert_feed([
        %{
          user_id: uuid(user_id),
          vault_id: uuid(vault_id),
          index_set: @index_set,
          op: @delete_vault
        }
      ])

      log_deletion(user_id, @delete_vault, vault_id, nil)
    end)
  end

  @spec delete_user(String.t()) :: :ok
  def delete_user(user_id) do
    in_tenant(user_id, fn ->
      insert_feed([%{user_id: uuid(user_id), index_set: @index_set, op: @delete_user}])
      log_deletion(user_id, @delete_user, nil, nil)
    end)
  end

  @doc "The note's current point set, read in the caller's tenant transaction."
  @spec note_points(String.t(), term()) :: [String.t()]
  def note_points(user_id, note_id) do
    in_tenant(user_id, fn ->
      Repo.all(
        from(c in Chunk,
          where: c.note_id == ^uuid(note_id) and not is_nil(c.qdrant_point_id),
          select: c.qdrant_point_id
        )
      )
    end)
  end

  defp note_row(scope, stamp),
    do: %{
      user_id: uuid(scope.user_id),
      vault_id: uuid(scope.vault_id),
      note_id: uuid(scope.note_id),
      index_set: @index_set,
      stamp: stamp
    }

  # The note's row lock (`ChunkRows` lock order: the note first; a no-op when
  # the index pass already holds it), then the stamp. A hard-deleted note has
  # no row left to lock; its stamp still rises past every earlier one.
  defp lock_and_stamp(note_id) do
    :ok = ChunkRows.lock_notes!([to_string(note_id)])
    %{rows: [[stamp]]} = Repo.query!("SELECT nextval('keyword_stamp_seq')", [])
    stamp
  end

  defp insert_feed([]), do: :ok

  defp insert_feed(rows) do
    # Same column set on every row (insert_all wants one shape).
    keys = ~w(user_id vault_id note_id point_id stamp index_set op terms keep)a
    rows = Enum.map(rows, fn r -> Map.new(keys, &{&1, Map.get(r, &1, default(&1))}) end)

    rows
    |> Enum.chunk_every(1_000)
    |> Enum.each(&Repo.insert_all(FeedRow, &1))
  end

  defp default(:stamp), do: 0
  defp default(_), do: nil

  defp log_deletion(user_id, op, vault_id, note_id) do
    {1, _} =
      Repo.insert_all(DeletionRow, [
        %{user_id: uuid(user_id), op: op, vault_id: uuid(vault_id), note_id: uuid(note_id)}
      ])

    :ok
  end

  defp in_tenant(user_id, fun), do: Repo.with_tenant!(to_string(user_id), fun)

  # Canonical uuid strings (the schemas dump them); raw 16-byte ids load.
  defp uuid(nil), do: nil
  defp uuid(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp uuid(id), do: to_string(id)
end
