defmodule Engram.Indexing.ChunkRows do
  @moduledoc """
  Writes a note's `chunks` rows by position, touching only what changed
  (`Engram.Indexing.commit_index/2` calls it inside its tenant transaction).

  A position the new rows no longer have is deleted, a new one inserted,
  and one whose content differs is updated in place, one statement per
  batch. It used to delete every row and reinsert them: a one-chunk edit of
  a 17-chunk note (the prod average) cost 17 deletes, 17 inserts and 85
  index entries (5 indexes); now it is one UPDATE. A row never changes its
  position, so `chunks_note_id_position_index` cannot collide mid-statement.
  An offset-only update (an edit shifts every later section) touches no
  indexed column, so it is HOT where the page has room (fillfactor 90,
  migration 20261025000100).

  Its own module so the one raw statement (the per-row-values UPDATE, a
  shape `update_all` cannot express) is the only raw SQL here, as
  `Notes.BulkRename` does for notes.
  """

  import Ecto.Query

  alias Engram.Notes.Chunk
  alias Engram.Repo

  # The columns a row is compared and rewritten on. `note_id`, `user_id`
  # and `vault_id` are the note's, so they never differ.
  @fields [:char_start, :char_end, :token_count, :qdrant_point_id, :context_hmac, :member_hmacs]

  @doc """
  Makes `note_id`'s rows equal `rows` (chunk row maps, one per position),
  `batch` rows a statement. Must run inside the owner's `Repo.with_tenant/2`.
  """
  @spec write!(Ecto.UUID.t(), [map()], pos_integer()) :: :ok
  def write!(note_id, rows, batch) do
    old =
      from(c in Chunk, where: c.note_id == ^note_id, select: map(c, [:position | @fields]))
      |> Repo.all()
      |> Map.new(&{&1.position, Map.delete(&1, :position)})

    new = MapSet.new(rows, & &1.position)
    gone = for p <- Map.keys(old), not MapSet.member?(new, p), do: p

    {added, changed} =
      Enum.split_with(rows, &(not Map.has_key?(old, &1.position)))

    changed = Enum.reject(changed, &(old[&1.position] == Map.take(&1, @fields)))

    if gone != [] do
      Repo.delete_all(
        from(c in Chunk,
          where:
            c.note_id == ^note_id and
              fragment("? = ANY(?)", c.position, type(^gone, {:array, :integer}))
        )
      )
    end

    changed |> Enum.chunk_every(batch) |> Enum.each(&update!(note_id, &1))

    # Batched: one statement for a big note overflows the protocol's bind
    # cap and kills the connection.
    added |> Enum.chunk_every(batch) |> Enum.each(&Repo.insert_all(Chunk, &1))
  end

  # The new values as arrays, one bind each. A merged row's `member_hmacs`
  # (ragged, so not a 2-D array) rides as JSON text.
  defp update!(note_id, rows) do
    col = fn key -> Enum.map(rows, &Map.get(&1, key)) end

    Repo.query!(
      """
      UPDATE chunks c SET char_start = u.cs, char_end = u.ce, token_count = u.tc,
        qdrant_point_id = u.pid, context_hmac = u.h,
        member_hmacs = CASE WHEN u.mh IS NULL THEN NULL
          ELSE ARRAY(SELECT jsonb_array_elements_text(u.mh::jsonb)) END
      FROM unnest($2::int4[], $3::int4[], $4::int4[], $5::int8[], $6::uuid[], $7::text[],
                  $8::text[]) AS u(pos, cs, ce, tc, pid, h, mh)
      WHERE c.note_id = $1 AND c.position = u.pos
      """,
      [
        Ecto.UUID.dump!(note_id),
        col.(:position),
        col.(:char_start),
        col.(:char_end),
        col.(:token_count),
        Enum.map(col.(:qdrant_point_id), &Ecto.UUID.dump!/1),
        col.(:context_hmac),
        Enum.map(col.(:member_hmacs), &(&1 && Jason.encode!(&1)))
      ]
    )

    :ok
  end
end
