defmodule Engram.Maintenance.ChangeFeed do
  @moduledoc """
  The notes written since a sweep's last run, read from the sync change
  sequence every write already maintains: `vaults.change_seq` (small table)
  says which vaults moved, then `notes (vault_id, seq, id)`
  (`notes_vault_id_seq_id_index`, the sync catch-up index) gives each moved
  vault's notes after the sweep's per-vault cursor. No index on a column a
  save writes is added (an `updated_at` index would end HOT saves).

  Not seen: a write that does not take a seq (the CRDT snapshot compaction,
  an append that clears `crdt_head`). Callers keep a bounded key-window
  backstop for those. Not capped across vaults, and the cursor row holds
  every live vault (~60 B each): fine at today's vault count; add a total cap
  with a round-robin when that grows.

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
  The live notes (`kind = 'note'`, not deleted) written since the last
  committed call for `name`, as `%{id, user_id, vault_id, version}`, and a
  `commit` function that moves the cursor past every row read. Call it only
  after the rows are consumed: a run that fails before it reads the same rows
  again next time (at least once; consumers are idempotent).
  """
  @spec changed(String.t(), pos_integer()) :: {[map()], (-> :ok)}
  def changed(name, per_vault \\ @per_vault) do
    cursor = Cursor.get(name) || %{}

    vaults =
      for [id, seq] <- on_pool(& &1.query!(@vaults, [], timeout: :timer.minutes(2)).rows),
          do: {Ecto.UUID.load!(id), seq}

    walk =
      Enum.flat_map(vaults, fn {id, seq} ->
        [s, last] = Map.get(cursor, id, [seq, @top])
        if s < seq or last != @top, do: [{id, s, last}], else: []
      end)

    read =
      if walk == [],
        do: [],
        else:
          on_pool(& &1.query!(@notes, params(walk, per_vault), timeout: :timer.minutes(2)).rows)

    by_vault = Enum.group_by(read, fn [_, _, v | _] -> Ecto.UUID.load!(v) end)

    walked = MapSet.new(walk, &elem(&1, 0))

    next =
      Map.new(vaults, fn {id, seq} ->
        page = Map.get(by_vault, id, [])

        cond do
          # A full page: more may follow at this exact position.
          length(page) >= per_vault ->
            [nid, _, _, _, s, _] = List.last(page)
            {id, [s, Ecto.UUID.load!(nid)]}

          # Caught up: jump to the `change_seq` read (or past the last row,
          # if a later write was read too). Safe: `Vaults.next_seq!/2` locks
          # the vault row from the bump to commit, so every write at or below
          # a committed `change_seq` is visible. A vault whose last change was
          # not a note (an attachment, a folder) is not walked again.
          MapSet.member?(walked, id) ->
            last_seq = page |> List.last() |> then(&((&1 && Enum.at(&1, 4)) || seq))
            {id, [max(seq, last_seq), @top]}

          true ->
            {id, Map.get(cursor, id, [seq, @top])}
        end
      end)

    rows =
      for [id, user_id, vault_id, version, _seq, true] <- read,
          do: %{
            id: Ecto.UUID.load!(id),
            user_id: Ecto.UUID.load!(user_id),
            vault_id: Ecto.UUID.load!(vault_id),
            version: version
          }

    {rows, fn -> Cursor.put(name, next) end}
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
  defp on_pool(read) do
    case TenantScan.pool() do
      {:fleet, repo} -> read.(repo)
      :per_user -> TenantScan.flat_map_users(fn _ -> read.(Repo) end)
    end
  end
end
