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
  UPDATE to the tenant's rows, and the shared `seq` keeps the #614
  one-op-one-seq contract. `rows` is [{note_id, stamp, kw}] where `kw`
  holds a value for every column in `cols`. A nested-collision unique
  violation raises Postgrex.Error exactly like the per-note update_all did.
  """
  @spec update!([{binary(), DateTime.t(), keyword()}], [atom()], integer()) :: :ok
  def update!([], _cols, _seq), do: :ok

  def update!(rows, cols, seq) do
    set_sql =
      Enum.map_join(cols, ", ", &"#{&1} = v.#{&1}") <> ", updated_at = v.updated_at, seq = $1"

    # id + updated_at + the class's columns, per VALUES row.
    ncols = length(cols) + 2

    rows
    |> Enum.chunk_every(@chunk)
    |> Enum.each(fn chunk ->
      values_sql =
        chunk
        |> Enum.with_index()
        |> Enum.map_join(", ", fn {_row, i} ->
          base = 2 + i * ncols

          col_placeholders =
            cols
            |> Enum.with_index(2)
            |> Enum.map_join(", ", fn {col, j} ->
              "$#{base + j}::#{sql_type(col)}"
            end)

          "($#{base}::uuid, $#{base + 1}::timestamp, #{col_placeholders})"
        end)

      params =
        [seq] ++
          Enum.flat_map(chunk, fn {id, stamp, kw} ->
            [
              Ecto.UUID.dump!(id),
              DateTime.to_naive(stamp) | Enum.map(cols, &Keyword.fetch!(kw, &1))
            ]
          end)

      _ =
        Repo.query!(
          """
          UPDATE notes AS n
          SET #{set_sql}
          FROM (VALUES #{values_sql}) AS v(id, updated_at, #{Enum.join(cols, ", ")})
          WHERE n.id = v.id
          """,
          params
        )
    end)

    :ok
  end

  defp sql_type(:tags_hmac), do: "bytea[]"
  defp sql_type(:dek_version), do: "integer"
  defp sql_type(:path_length), do: "integer"
  defp sql_type(_col), do: "bytea"
end
