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

  # x at most 16 params per row: far under Postgres's 65535-bind-param limit
  @chunk 500

  @doc "Rows per statement. `:attachments_bulk_chunk` lowers it (tests)."
  @spec chunk_size() :: pos_integer()
  def chunk_size, do: min(Application.get_env(:engram, :attachments_bulk_chunk, @chunk), @chunk)

  @set %{
    delete: "deleted_at = $1, updated_at = $1, seq = v.seq",
    touch: "updated_at = $1, seq = v.seq"
  }
  @move_cols [
    path_ciphertext: "bytea",
    path_nonce: "bytea",
    path_hmac: "bytea",
    basename_hmac: "bytea",
    path_ci_hmac: "bytea",
    path_length: "integer",
    link_keys_stamp: "bytea",
    name_ciphertext: "bytea",
    name_nonce: "bytea",
    name_hmac: "bytea",
    name_ci_hmac: "bytea",
    name_stamp: "bytea",
    folder_ref_id: "uuid",
    folder_ref_stamp: "bytea"
  ]

  @doc """
  Repoints live rows to new paths: `rows` is `[{id, seq, cols}]` where `cols`
  holds a value for every `@move_cols` column (VALUES order, SQL types). One
  UPDATE per chunk; returns how many rows moved. A live-path unique violation
  raises, rolling the caller's transaction back.
  """
  @spec move!([{binary(), integer(), keyword()}], DateTime.t()) :: non_neg_integer()
  def move!(rows, now) do
    names = Keyword.keys(@move_cols)
    set_sql = Enum.map_join(names, ", ", &"#{&1} = v.#{&1}") <> ", updated_at = $1, seq = v.seq"
    width = length(@move_cols) + 2

    rows
    |> Enum.chunk_every(chunk_size())
    |> Enum.reduce(0, fn chunk, acc ->
      values_sql =
        chunk
        |> Enum.with_index()
        |> Enum.map_join(", ", fn {_row, i} ->
          base = 2 + i * width

          cols =
            @move_cols
            |> Enum.with_index(2)
            |> Enum.map_join(", ", fn {{_name, type}, j} -> "$#{base + j}::#{type}" end)

          "($#{base}::uuid, $#{base + 1}::bigint, #{cols})"
        end)

      params = [
        now
        | Enum.flat_map(chunk, fn {id, seq, cols} ->
            [Ecto.UUID.dump!(id), seq | Enum.map(names, &dump_col(&1, Keyword.fetch!(cols, &1)))]
          end)
      ]

      %{num_rows: n} =
        Repo.query!(
          """
          UPDATE attachments AS a
          SET #{set_sql}
          FROM (VALUES #{values_sql}) AS v(id, seq, #{Enum.join(names, ", ")})
          WHERE a.id = v.id AND a.deleted_at IS NULL
          """,
          params
        )

      acc + n
    end)
  end

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
    |> Enum.chunk_every(chunk_size())
    |> Enum.flat_map(fn chunk ->
      values_sql =
        chunk
        |> Enum.with_index()
        |> Enum.map_join(", ", fn {_pair, i} -> "($#{i * 2 + 2}::uuid, $#{i * 2 + 3}::bigint)" end)

      params = [
        now
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

  # The folder ref is a UUID string (or nil, the root) in the caller's columns.
  defp dump_col(:folder_ref_id, nil), do: nil
  defp dump_col(:folder_ref_id, id), do: Ecto.UUID.dump!(id)
  defp dump_col(_name, value), do: value

  @doc """
  The set-based form of `Engram.Folders.Rows.attachment_ref/2`, ONE
  statement for any number of rows and folders: each
  `{id, folder_ref, nonce, stamp}` (dumped uuids, `folder_ref` nil at the
  root) is written only where the row still holds the `nonce` its path was
  read under (a path rewritten since is that writer's, stamped by it).
  `stamp` is the nonce, or `Engram.Folders.Rows.unreadable_attachment_stamp/1`.
  Rows another transaction holds are skipped (the caller's own are not).
  Run through `repo`: `Engram.Repo` inside the restore's `Repo.with_tenant/2`
  transaction, or `FolderTable`'s per-user scope (`Repo.with_tenant!/2`, or
  the maintenance pool where there is one). Returns the rows updated.
  """
  @spec point_attachments(module(), [{binary(), binary() | nil, binary(), binary()}]) ::
          non_neg_integer()
  def point_attachments(_repo, []), do: 0

  def point_attachments(repo, rows) do
    {ids, refs, nonces, stamps} =
      Enum.reduce(Enum.reverse(rows), {[], [], [], []}, fn {id, ref, nonce, stamp},
                                                           {i, r, n, st} ->
        {[id | i], [ref | r], [nonce | n], [stamp | st]}
      end)

    %{num_rows: count} =
      repo.query!(
        """
        WITH locked AS (SELECT id FROM attachments WHERE id = ANY($1::uuid[]) FOR UPDATE SKIP LOCKED)
        UPDATE attachments a SET folder_ref_id = v.fid, folder_ref_stamp = v.stamp
        FROM unnest($1::uuid[], $2::uuid[], $3::bytea[], $4::bytea[]) AS v(id, fid, nonce, stamp),
             locked l
        WHERE a.id = v.id AND l.id = a.id AND a.path_nonce = v.nonce
        """,
        [ids, refs, nonces, stamps]
      )

    count
  end
end
