defmodule Engram.Notes.MovedFeedSql do
  @moduledoc """
  The moved-folder feed's note-id leg (`Engram.Notes.list_moved_changes/4`):
  raw SQL, a `UNION ALL` of one `ORDER BY id LIMIT k` child per subfolder,
  which Ecto cannot build as a lazy Merge Append. Runs inside the caller's
  `Repo.with_tenant/2` transaction, so RLS tenant context is active. Its own
  small file so `notes.ex` needs no raw-SQL or sobelow exemption. Every
  value is a parameter; only the child count and the fixed `@moved_preds`
  are spliced in.
  """

  alias Engram.Repo

  # Subfolders per statement of `ids/6`, per leg (`:live` and `:dead`
  # each send their own).
  @moved_children 256

  @moved_preds %{
    live: "deleted_at IS NULL AND kind = 'note' AND seq < $3",
    dead: "deleted_at IS NOT NULL AND kind = 'note' AND seq > $3"
  }

  @doc """
  The first `k` note ids, in id order, past `from_id`, of `refs`' folders:
  `:live` notes not written since the move (`seq < folder_seq`; a later
  write rides its own row), or `:dead` ones that died after it. One lazy
  Merge Append per 256 subfolders: a child per subfolder, `ORDER BY id
  LIMIT k` on `notes_folder_ref_live_id` (or `notes_folder_ref_dead_id`),
  under an outer `ORDER BY id LIMIT k`. One array parameter.

  ponytail: a page reads `k + F + R` index entries per leg: `k` served, one
  descent per subfolder F, and R rejected by the seq filter above the
  cursor. Dead: index-only (`seq` is INCLUDEd), so R is tombstones older
  than the move. Live: `seq` is a heap check, and R is notes edited since
  the move (each also served on its own row). Past 256 subfolders the
  chunks each read `k` and are merged here: `ceil(F / 256) x k + F + R`.
  """
  @spec ids(
          Ecto.UUID.t(),
          [Ecto.UUID.t()],
          :live | :dead,
          integer(),
          Ecto.UUID.t() | nil,
          pos_integer()
        ) ::
          [Ecto.UUID.t()]
  def ids(_vault_id, [], _which, _folder_seq, _from_id, _k), do: []

  def ids(vault_id, refs, which, folder_seq, from_id, k) do
    after_raw = Ecto.UUID.dump!(from_id || "00000000-0000-0000-0000-000000000000")
    vault_raw = Ecto.UUID.dump!(vault_id)

    refs
    |> Enum.map(&Ecto.UUID.dump!/1)
    |> Enum.chunk_every(@moved_children)
    |> Enum.flat_map(fn chunk ->
      # A fixed width per chunk (`width/1`): the slots past the
      # chunk's folders are NULL and match nothing, so there are three
      # statement shapes, not one per subtree size.
      %{rows: rows} =
        Repo.query!(sql(which, width(length(chunk))), [
          vault_raw,
          chunk,
          folder_seq,
          after_raw,
          k
        ])

      Enum.map(rows, fn [id] -> id end)
    end)
    |> Enum.sort()
    |> Enum.take(k)
    |> Enum.map(&Ecto.UUID.load!/1)
  end

  defp width(n) when n <= 8, do: 8
  defp width(n) when n <= 32, do: 32
  defp width(_n), do: @moved_children

  @doc "The statement `ids/6` sends for `n` subfolders (also the plan test's)."
  @spec sql(:live | :dead, pos_integer()) :: String.t()
  def sql(which, n) do
    pred = Map.fetch!(@moved_preds, which)

    children =
      Enum.map_join(1..n, " UNION ALL ", fn i ->
        "(SELECT id FROM notes WHERE vault_id = $1 AND folder_ref_id = ($2::uuid[])[#{i}] " <>
          "AND #{pred} AND id > $4 ORDER BY id LIMIT $5)"
      end)

    "SELECT id FROM (#{children}) AS u ORDER BY id LIMIT $5"
  end
end
