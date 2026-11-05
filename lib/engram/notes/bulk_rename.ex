defmodule Engram.Notes.BulkRename do
  @moduledoc """
  The folder-rename cascade's batch `UPDATE notes ... FROM (VALUES ...)`.

  Its own small file so Sobelow's pinned `SQL.Query` fingerprint, which
  includes the line number, stays put. Inside `notes.ex` it shifted on most PRs
  and broke CI (docs/context/sobelow-silent-no-op-and-fingerprint-skips.md).

  The interpolation builds query SHAPE only: `$N` placeholders, column names
  from `Engram.Notes`' compile-time rename column lists, and `sql_type/1`.
  Every value is a bind parameter. Keep `cols` compile-time constants.
  """

  alias Engram.Repo

  # Same bound as Engram.Notes' @rename_update_chunk: 500 rows x <=16 params
  # stays well under Postgres's 65535-bind-param protocol limit.
  @chunk 500

  @doc """
  One `UPDATE notes ... FROM (VALUES ...)` per ≤500-row chunk. Every row in a
  class gets DISTINCT ciphertexts, so this can't be a single update_all — but
  it must not be one UPDATE per note either (the N+1 this replaces). Runs
  inside the caller's with_tenant transaction: the RLS role restricts the raw
  UPDATE to the tenant's rows, and the shared `seq` and `stamp` keep the
  #614 one-op-one-seq contract. `rows` is [{note_id, kw}], `kw` holding a
  value for every column in `cols`. A nested-collision unique violation
  raises Postgrex.Error exactly like the per-note update_all did.
  """
  @spec update!([{binary(), keyword()}], [atom()], integer(), DateTime.t()) :: :ok
  def update!([], _cols, _seq, _stamp), do: :ok

  def update!(rows, cols, seq, stamp) do
    # `updated_at = $2`, uncast: Postgres types it from the column, so a UTC
    # DateTime lands as the same instant whether the column is `timestamp`
    # or `timestamptz`, whatever the session TimeZone.
    set_sql = Enum.map_join(cols, ", ", &"#{&1} = v.#{&1}") <> ", updated_at = $2, seq = $1"
    ncols = length(cols) + 1

    rows
    |> Enum.chunk_every(@chunk)
    |> Enum.each(fn chunk ->
      values_sql =
        chunk
        |> Enum.with_index()
        |> Enum.map_join(", ", fn {_row, i} ->
          # id + the class's columns, per VALUES row.
          base = 3 + i * ncols

          col_placeholders =
            cols
            |> Enum.with_index(1)
            |> Enum.map_join(", ", fn {col, j} ->
              "$#{base + j}::#{sql_type(col)}"
            end)

          "($#{base}::uuid, #{col_placeholders})"
        end)

      # $1 = seq, $2 = the cascade's shared stamp (a UTC DateTime), then
      # each row's id and columns.
      params =
        [seq, stamp] ++
          Enum.flat_map(chunk, fn {id, kw} ->
            [Ecto.UUID.dump!(id) | Enum.map(cols, &Keyword.fetch!(kw, &1))]
          end)

      _ =
        Repo.query!(
          """
          UPDATE notes AS n
          SET #{set_sql}
          FROM (VALUES #{values_sql}) AS v(id, #{Enum.join(cols, ", ")})
          WHERE n.id = v.id
          """,
          params
        )

      sync_bodies(chunk, cols)
    end)

    :ok
  end

  # A class that rewrites a body column (or the key version) keeps
  # `note_bodies` in step, chunk by chunk, in the caller's transaction.
  # (Below `update!/4`, and no alias, so the pinned `Repo.query!` line stays.)
  defp sync_bodies(chunk, cols) do
    if Enum.any?(cols, &(&1 in [:dek_version | Engram.Notes.NoteBody.body_fields()])),
      do: Engram.Notes.NoteBody.sync!(Enum.map(chunk, &elem(&1, 0)), cols)
  end

  defp sql_type(:tags_hmac), do: "bytea[]"
  defp sql_type(:dek_version), do: "integer"
  defp sql_type(:path_length), do: "integer"
  defp sql_type(_col), do: "bytea"
end
