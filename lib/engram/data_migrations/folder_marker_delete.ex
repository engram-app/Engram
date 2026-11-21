defmodule Engram.DataMigrations.FolderMarkerDelete do
  @moduledoc """
  Deletes the `kind = 'folder'` marker rows once markers have stopped (S6
  step 4, Engram#2523): every listing reads `folders.explicit` (phase 1) and
  no writer inserts a marker (phase 2, `Engram.Folders.MarkerStop`), so a
  marker is redundant with its folder row. `done?/0` is what the step 3 write
  stop (`PathHashStop`) waits for: a vault-wide marker read is cheap only once
  none are left.

  Blocked (the pass walks nothing, resets its walk and stays open) unless
  `MarkerStop.on?/0` (no writer can still insert a marker) AND the rollback
  floor is at or above release E (`@stop_release`), so no release a rollback
  can land on still READS markers: a marker deleted here is gone for good.
  The floor-to-E PR set it to E's tag and listed 2649's merge commit in
  `priv/release_floor_contains`.
  `:marker_delete_floors, :assume` (tests only) skips that check.

  Only LIVE markers are deleted. A trashed marker (`deleted_at` set) is trash
  history: it stays, as every trash row does until a trash purge is approved.
  No live read path reads one (listings, the scan's marker arm
  `folder_markers_in`, `live_folder_marker_hmacs` filter `deleted_at IS NULL`);
  only the undo (`Notes.plan_restore/4`, by op) and the marker lookup of a
  path delete (`find_folder_marker`, which then clears the flag) see them.

  Before a live marker goes, its live, explicit folder row is stamped
  (`explicit_seq` 0 unless set), so `ExplicitFolderReconcile` never clears it.
  A vault holding ANY live marker without such a row is not touched at all on
  that pass (redundancy pre-check, logged once per vault per day with the
  vault id and the count): an unmatched marker is never deleted, and it keeps
  the ledger open until `FolderTable` or a writer repairs the row.

  Re-verified daily (`reverify?/0`): a rollback to release D, whose writers
  insert markers, and a roll forward would leave `done?/0` true with markers
  present. The daily walk finds them and reopens the ledger. A caller that
  needs to know NOW for one vault asks `done?/2` (the ledger plus one index
  probe).

  Paced: at most `folder_marker_delete_max_fixed` markers a pass (service
  override, default #{2_000}), so the fleet's WAL and dead tuples spread over
  hourly passes.

  Discovery and writes go through `Engram.Backfill.IdWindows.heal_pass/4`
  (`notes` primary-key windows of 200; one fleet walk on the maintenance pool
  on SaaS, per tenant on self-host). Each window is one transaction under
  `SET LOCAL lock_timeout = '2s'` and `statement_timeout = '5s'`, with the
  ordering `ExplicitFolderReconcile` uses: first the window's vault rows
  `FOR SHARE SKIP LOCKED` in their own statement, then the checks and writes
  in later statements, whose fresh snapshots see every write committed
  before the lock (every folder and marker writer takes its vault row first).
  A row a writer holds, or a vault one holds, is skipped and counts as left.

  Kill switch: `enabled?/0` is the `folder_marker_delete` service override,
  DEFAULT OFF: it is switched on in prod only once release E is verified and
  the re-probe in #2523 reads 0. Off, no pass runs and the ledger stays open.
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.Backfill.IdWindows
  alias Engram.DataMigrations
  alias Engram.DataMigrations.VaultLock
  alias Engram.Folders.MarkerStop
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note

  require Logger

  @batch 200
  # The release with the marker write stop (release E, #2649).
  @stop_release "release-v0.91.0"
  @max_fixed 2_000

  @impl true
  def name, do: "folder_marker_delete"

  @impl true
  def version, do: 1

  @doc """
  True once no live marker is left (the ledger is done). Re-verified daily
  (`reverify?/0`), so after a rollback to D and back it can be true for up to
  a day with markers present; use `done?/2` where that matters for one vault.
  """
  @spec done?() :: boolean()
  def done?, do: DataMigrations.done?(name(), version())

  @doc """
  `done?/0` AND no live marker in `vault_id` right now: one probe of
  `notes_user_vault_folder_marker` (`LIMIT 1`, O(1)). Runs inside the
  caller's tenant transaction (`user_id` is the vault owner).
  """
  @spec done?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def done?(user_id, vault_id) do
    done?() and
      not Engram.Repo.exists?(
        from(n in Note,
          where:
            n.user_id == ^user_id and n.vault_id == ^vault_id and n.kind == "folder" and
              is_nil(n.deleted_at)
        )
      )
  end

  @impl true
  def reverify?, do: true

  @doc "The first release that writes no marker: the rollback floor must reach it."
  @spec stop_release() :: String.t()
  def stop_release, do: @stop_release

  @doc "Whether the rollback floor covers the marker write stop release."
  @spec floors?(:assume | :enforce) :: boolean()
  def floors?(mode \\ Engram.ServiceConfig.env(:marker_delete_floors, :enforce)),
    do: mode == :assume or Engram.Release.Floor.at_least?(@stop_release)

  @doc """
  Kill switch: the `folder_marker_delete` service override, default OFF.
  """
  @impl true
  def enabled?, do: Engram.ServiceConfig.get(:folder_marker_delete, false) == true

  @impl true
  def run_pass, do: run_pass([])

  @doc false
  # `batch:` overrides the window size.
  def run_pass(opts) do
    if MarkerStop.on?() and floors?() do
      IdWindows.heal_pass(name(), Note, &delete/2,
        batch_size: Keyword.get(opts, :batch, @batch),
        max_fixed: Keyword.get_lazy(opts, :max_fixed, &max_fixed/0)
      )
    else
      IdWindows.reset_walk(name())
      :ok = Engram.DataMigration.report(blocked: :markers_not_stopped)
      {:more, rows: 0, blocked: 1}
    end
  end

  # Statement 1: the window's live markers (`[id, vault, owner]`). The
  # window's notes are read by primary key alone in a MATERIALIZED CTE and
  # filtered outside it: with `kind = 'folder' AND deleted_at IS NULL` on
  # the scan, the planner ANDed in `notes_user_vault_folder_marker` read with
  # no condition (every account's live markers; staging, real statistics).
  #
  # Statement 2: their vault rows (and owners) FOR SHARE SKIP LOCKED
  # (`Engram.DataMigrations.VaultLock`), so the later statements take their
  # snapshot after the lock (see `ExplicitFolderReconcile`).
  @window_markers_sql """
  WITH w AS MATERIALIZED (
    SELECT id, vault_id, user_id, kind, deleted_at FROM notes WHERE id = ANY($1))
  SELECT id, vault_id, user_id FROM w WHERE kind = 'folder' AND deleted_at IS NULL
  """

  # The live folder rows at a marker's path (`m`, the marker): a key lookup
  # on `folders_full_path (vault_id, full_path_hmac) WHERE full_path_hmac IS
  # NOT NULL AND deleted_at IS NULL`, O(1) a marker (`deleted_at IS NULL`
  # stays on the scan to match that predicate). Its callers check the tenant,
  # `explicit` (and `explicit_seq`) above the OFFSET 0 fence: on the scan,
  # `explicit` qualifies the partial `folders_explicit_user_vault (user_id,
  # vault_id)`, which prod's planner chose, reading every explicit folder of
  # the vault per marker (prod EXPLAIN, 2026-11-21). Shared by statements 3
  # and 4.
  @folders_at_marker """
  SELECT id, user_id, explicit, explicit_seq FROM folders
  WHERE vault_id = m.vault_id AND full_path_hmac = m.folder_hmac AND deleted_at IS NULL
  OFFSET 0
  """

  # Statement 3: of the locked vaults (`$1` ids, `$2` their owners, paired by
  # position), those holding a live marker with no live explicit folder row at
  # its path hash, and how many such markers each has. Vault-wide: a
  # `(user_id, vault_id)` range of `notes_user_vault_folder_marker`, then one
  # folder key lookup a marker (`@folders_at_marker`): O(the vault's
  # markers), once a window.
  # A scalar subquery, not NOT EXISTS: Postgres never pulls it up into a
  # join, so it stays one parameterized probe per marker. As an anti join
  # the planner could hash every explicit folder row of every tenant
  # (`folders_explicit_user_vault` read with no condition), which it did on
  # a small test table.
  @unmatched_sql """
  SELECT m.vault_id, count(*)::int
  FROM unnest($1::uuid[], $2::uuid[]) AS v(id, user_id)
  JOIN notes AS m
    ON m.user_id = v.user_id AND m.vault_id = v.id AND m.kind = 'folder' AND m.deleted_at IS NULL
  WHERE (
    SELECT 1 FROM (#{@folders_at_marker}) AS f
    WHERE f.user_id = m.user_id AND f.explicit
    LIMIT 1) IS NULL
  GROUP BY m.vault_id
  """

  # Statement 4: the markers of the vaults that passed (`$1`, from statement
  # 1: in a locked, matched vault and owned by its owner), locked by primary
  # key alone from a bound array, then re-checked on the locked rows (a
  # locking read returns the row's latest version: still a live marker of
  # vault `$2`, owner `$3`), each with the id of its live explicit folder row
  # still to stamp. With the marker filters on the scan the planner read
  # `notes_folder_ref` by vault (every note of the vault). One key lookup a
  # marker (`@folders_at_marker`), the marker's tenant re-checked on the row,
  # so O(markers in the window). An ARRAY
  # sublink is never pulled up into a join, so it stays a probe a marker;
  # the CTE locks the markers before any probe runs.
  @markers_sql """
  WITH m AS MATERIALIZED (
    SELECT n.id, n.user_id, n.vault_id, n.folder_hmac, n.kind, n.deleted_at FROM notes AS n
    WHERE n.id = ANY($1::uuid[])
    ORDER BY n.id
    FOR UPDATE OF n SKIP LOCKED
  )
  SELECT m.id, m.user_id, m.vault_id, ARRAY(
    SELECT f.id FROM (#{@folders_at_marker}) AS f
    WHERE f.user_id = m.user_id AND f.explicit AND f.explicit_seq IS NULL)
  FROM m
  WHERE m.kind = 'folder' AND m.deleted_at IS NULL
    AND m.user_id = ANY($3) AND m.vault_id = ANY($2)
  """

  # Statement 5, once per folder row from statement 4: the row stamped by
  # its primary key, a scalar, so O(markers in the window), capped by the
  # window (`@batch`). By an array of ids the planner costed the key probe
  # as a guess: an ARRAY sublink read `folders_explicit_user_vault` with no
  # condition, every tenant's explicit rows (0.91.0's CI). By `id` alone:
  # a `vault_id`/`user_id` equality here makes the partial explicit-folder
  # indexes usable, and they tie with the key probe. The row's tenant and
  # vault come from statement 4's probe, under the vault lock. The guards
  # again on the row itself: re-checked on the row's latest version when it
  # waited on a concurrent writer's lock, so a row stamped meanwhile keeps
  # its seq (defence in depth beyond the vault lock).
  @stamp_sql """
  UPDATE folders SET explicit_seq = 0
  WHERE id = $1 AND explicit_seq IS NULL AND explicit AND deleted_at IS NULL
  """

  # Statement 6: the markers locked by statement 4, by primary key.
  @delete_sql "DELETE FROM notes AS n WHERE n.id = ANY($1::uuid[])"

  # What is left in a window: any live marker (a skipped lock or an
  # unmatched vault). Read by primary key alone, as statement 1.
  @left_sql """
  WITH w AS MATERIALIZED (SELECT kind, deleted_at FROM notes WHERE id = ANY($1))
  SELECT count(*)::int FROM w WHERE kind = 'folder' AND deleted_at IS NULL
  """

  @doc false
  def window_markers_sql, do: @window_markers_sql
  @doc false
  def unmatched_sql, do: @unmatched_sql
  @doc false
  def markers_sql, do: @markers_sql
  @doc false
  def stamp_sql, do: @stamp_sql
  @doc false
  def delete_sql, do: @delete_sql

  @doc false
  # The per-pass cap: the service override when it is a positive integer,
  # else the default, with a warning.
  def max_fixed do
    case Engram.ServiceConfig.get(:folder_marker_delete_max_fixed, @max_fixed) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        Logger.warning(
          "folder_marker_delete_max_fixed is not a positive integer, using #{@max_fixed}",
          Metadata.with_category(:warning, :data)
        )

        @max_fixed
    end
  end

  defp delete(ids, %{repo: repo}) do
    ids = Enum.map(ids, &Ecto.UUID.dump!/1)
    _ = repo.query!("SET LOCAL lock_timeout = '2s'", [])
    _ = repo.query!("SET LOCAL statement_timeout = '5s'", [])

    %{rows: window} = repo.query!(@window_markers_sql, [ids])
    vaults = window |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()

    case VaultLock.lock(repo, vaults) do
      [] ->
        {0, left?(repo, ids)}

      locked ->
        vaults = Enum.map(locked, &hd/1)
        owners = Enum.map(locked, &List.last/1)
        %{rows: unmatched} = repo.query!(@unmatched_sql, [vaults, owners])
        Enum.each(unmatched, fn [vault, count] -> log_unmatched(vault, count) end)
        warn_foreign_owner(window, locked)
        skipped = Enum.map(unmatched, &hd/1)
        passed = Enum.reject(locked, &(hd(&1) in skipped))
        owner = Map.new(passed, fn [vault, user] -> {vault, user} end)
        markers = for [id, vault, user] <- window, owner[vault] == user, do: id
        {ok, ok_owners} = owners_by_vault(passed)
        {marker_ids, stamp} = lock_markers(repo, markers, ok, ok_owners)
        stamp_folders(repo, stamp)
        {delete_markers(repo, marker_ids), left?(repo, ids)}
    end
  end

  # Live markers of a locked vault whose `user_id` is not the vault owner's:
  # the markers lock binds the owners, so they are never deleted and the
  # ledger stays open. Not widened on purpose (a row owned by another tenant
  # is not this vault's to act on); logged once per vault per node per day,
  # with the count, so an open ledger says why.
  defp warn_foreign_owner(window, locked) do
    owner = Map.new(locked, fn [vault, user] -> {vault, user} end)

    window
    |> Enum.filter(fn [_id, vault, user] ->
      Map.has_key?(owner, vault) and owner[vault] != user
    end)
    |> Enum.frequencies_by(&Enum.at(&1, 1))
    |> Enum.each(fn {vault, count} ->
      Engram.Cache.fetch(:marker_delete_warned, {:foreign_owner, vault}, fn ->
        Logger.warning(
          "folder_marker_delete: live markers whose owner is not the vault's, skipped",
          Metadata.with_category(:warning, :data,
            vault_id: Ecto.UUID.load!(vault),
            count: count
          )
        )

        true
      end)
    end)
  end

  defp owners_by_vault(locked),
    do: {Enum.map(locked, &hd/1), locked |> Enum.map(&List.last/1) |> Enum.uniq()}

  # Statements 4 to 6 run in the window's transaction, under its vault lock.
  # Statement 4's rows: `[marker id, user id, vault id, folder ids]`; `ids`
  # the markers statement 1 found in the passed vaults.
  defp lock_markers(_repo, [], _vaults, _owners), do: {[], []}

  defp lock_markers(repo, ids, vaults, owners) do
    %{rows: rows} = repo.query!(@markers_sql, [ids, vaults, owners])
    {Enum.map(rows, &hd/1), rows}
  end

  defp stamp_folders(repo, rows) do
    for [_marker, _user, _vault, folders] <- rows,
        folder <- folders,
        do: repo.query!(@stamp_sql, [folder])

    :ok
  end

  defp delete_markers(_repo, []), do: 0

  defp delete_markers(repo, ids) do
    %{num_rows: n} = repo.query!(@delete_sql, [ids])
    n
  end

  defp left?(repo, ids) do
    %{rows: [[left]]} = repo.query!(@left_sql, [ids])
    left > 0
  end

  # Once per vault per node per day (`:marker_delete_warned`, 24 h TTL), not
  # once per window per hourly pass.
  defp log_unmatched(vault, count) do
    Engram.Cache.fetch(:marker_delete_warned, vault, fn ->
      warn_unmatched(vault, count)
      true
    end)
  end

  defp warn_unmatched(vault, count) do
    Logger.warning(
      "folder_marker_delete: vault skipped, live markers without an explicit folder row",
      Metadata.with_category(:warning, :data,
        vault_id: Ecto.UUID.load!(vault),
        count: count
      )
    )
  end
end
