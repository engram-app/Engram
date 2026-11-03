defmodule Engram.Maintenance.ChangeFeed do
  @moduledoc """
  The notes written since a sweep's last run, read from the sync change
  sequence every write already maintains: `vaults.change_seq` (small table)
  says which vaults moved, then `notes (vault_id, seq, id)`
  (`notes_vault_id_seq_id_index`, the sync catch-up index) gives each moved
  vault's notes after the sweep's per-vault cursor. No index on a column a
  save writes is added (an `updated_at` index would end HOT saves).

  Not seen: a write that does not take a seq (the CRDT snapshot compaction,
  an append that clears `crdt_head`), and a write that commits after a
  higher seq was read. Callers keep a bounded key-window backstop for those.

  The cursor (`Engram.Maintenance.Cursor`, one row per sweep) maps each live
  vault to the `[seq, id]` read up to; a vault first seen starts at its current
  `change_seq` (no history walk). At most `per_vault` notes per vault per run;
  a vault with more continues next run.
  """
  alias Engram.Backfill.TenantScan
  alias Engram.Maintenance.Cursor
  alias Engram.Repo

  @per_vault 1_000
  # Greater than every uuid: `[seq, @top]` means "all of seq read".
  @top "ffffffff-ffff-ffff-ffff-ffffffffffff"

  @vaults "SELECT id, change_seq FROM vaults WHERE deleted_at IS NULL"

  @notes """
  SELECT n.id, n.user_id, n.vault_id, n.version, n.seq,
         n.kind = 'note' AND n.deleted_at IS NULL AS live
  FROM unnest($1::uuid[], $2::bigint[], $3::uuid[]) AS c(vault_id, seq, id)
  CROSS JOIN LATERAL (
    SELECT n.id, n.user_id, n.vault_id, n.version, n.seq, n.kind, n.deleted_at
    FROM notes n
    WHERE n.vault_id = c.vault_id AND (n.seq, n.id) > (c.seq, c.id)
    ORDER BY n.seq, n.id
    LIMIT $4) n
  """

  @doc false
  def notes_sql, do: @notes

  @doc """
  The live notes (`kind = 'note'`, not deleted) written since the last call
  for `name`, as `%{id, user_id, vault_id, version}`, and the cursor moved
  past every row read.
  """
  @spec changed(String.t(), pos_integer()) :: [map()]
  def changed(name, per_vault \\ @per_vault) do
    cursor = Cursor.get(name) || %{}
    vaults = for [id, seq] <- rows(@vaults, []), do: {Ecto.UUID.load!(id), seq}

    walk =
      Enum.flat_map(vaults, fn {id, seq} ->
        [s, last] = Map.get(cursor, id, [seq, @top])
        if s < seq or last != @top, do: [{id, s, last}], else: []
      end)

    read = if walk == [], do: [], else: rows(@notes, params(walk, per_vault))
    by_vault = Enum.group_by(read, fn [_, _, v | _] -> Ecto.UUID.load!(v) end)

    next =
      Map.new(vaults, fn {id, seq} ->
        case Map.get(by_vault, id) do
          nil ->
            {id, Map.get(cursor, id, [seq, @top]) |> caught_up(id, walk)}

          page ->
            [nid, _, _, _, s, _] = List.last(page)
            {id, if(length(page) >= per_vault, do: [s, Ecto.UUID.load!(nid)], else: [s, @top])}
        end
      end)

    :ok = Cursor.put(name, next)

    for [id, user_id, vault_id, version, _seq, true] <- read,
        do: %{
          id: Ecto.UUID.load!(id),
          user_id: Ecto.UUID.load!(user_id),
          vault_id: Ecto.UUID.load!(vault_id),
          version: version
        }
  end

  # A walked vault with no row after its cursor has read everything there is
  # (its seq moved for attachments only, say). The cursor stays at the last
  # seq read, never jumps to `change_seq`: a write holding a lower seq may
  # still be uncommitted.
  defp caught_up([s, last], id, walk) do
    if Enum.any?(walk, &(elem(&1, 0) == id)), do: [s, @top], else: [s, last]
  end

  defp params(walk, per_vault) do
    [
      Enum.map(walk, &Ecto.UUID.dump!(elem(&1, 0))),
      Enum.map(walk, &elem(&1, 1)),
      Enum.map(walk, &Ecto.UUID.dump!(elem(&1, 2))),
      per_vault
    ]
  end

  # One statement on the maintenance pool on SaaS; per tenant elsewhere (RLS
  # scopes each read to that tenant's vaults and notes).
  defp rows(sql, params) do
    case TenantScan.pool() do
      {:fleet, repo} ->
        repo.query!(sql, params, timeout: :timer.minutes(2)).rows

      :per_user ->
        TenantScan.flat_map_users(fn _ -> Repo.query!(sql, params).rows end)
    end
  end
end
