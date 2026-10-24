defmodule Engram.Attachments.BulkUpdate do
  @moduledoc """
  The attachments table's batch `UPDATE ... FROM (VALUES ...)` statements:
  rows that each need their OWN value (a distinct seq), which `update_all`
  cannot express, in one statement per chunk instead of one per row.

  Its own small file so Sobelow's pinned `SQL.Query` fingerprint, which
  includes the line number, stays put (see
  docs/context/sobelow-silent-no-op-and-fingerprint-skips.md).

  The interpolation builds query SHAPE only: `$N` placeholders and a SET
  clause picked from the compile-time `@set` map by atom. Every value is a
  bind parameter. Runs inside the caller's `Repo.with_tenant/2` transaction,
  so the RLS role restricts it to the tenant's rows.
  """

  alias Engram.Repo

  # 500 rows x 2 params, far under Postgres's 65535-bind-param limit.
  @chunk 500

  @set %{
    delete: "deleted_at = $1, updated_at = $1, seq = v.seq",
    touch: "updated_at = $1, seq = v.seq"
  }

  @doc """
  Stamps each `{id, seq}` row its own seq (plus `mode`'s SET columns, `now`
  as `$1`), live rows only. `deleted_at IS NULL` re-guards a row a concurrent
  transaction deleted after the caller read it: it is skipped and its seq
  goes unused (gaps are fine, the feed only needs monotonic-unique). Returns
  `[{id, path_hmac}]` for the rows actually updated.
  """
  @spec stamp_seqs!([{binary(), integer()}], :delete | :touch, DateTime.t()) ::
          [{binary(), binary()}]
  def stamp_seqs!(id_seqs, mode, now) do
    set_sql = Map.fetch!(@set, mode)

    id_seqs
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      values_sql =
        chunk
        |> Enum.with_index()
        |> Enum.map_join(", ", fn {_pair, i} -> "($#{i * 2 + 2}::uuid, $#{i * 2 + 3}::bigint)" end)

      params = [
        DateTime.to_naive(now)
        | Enum.flat_map(chunk, fn {id, seq} -> [Ecto.UUID.dump!(id), seq] end)
      ]

      %{rows: rows} =
        Repo.query!(
          """
          UPDATE attachments AS a
          SET #{set_sql}
          FROM (VALUES #{values_sql}) AS v(id, seq)
          WHERE a.id = v.id AND a.deleted_at IS NULL
          RETURNING a.id, a.path_hmac
          """,
          params
        )

      # Raw query: the uuid comes back as 16 bytes; load!/1 gives the dashed form.
      for [id, hmac] <- rows, do: {Ecto.UUID.load!(id), hmac}
    end)
  end
end
