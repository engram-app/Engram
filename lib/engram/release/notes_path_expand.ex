defmodule Engram.Release.NotesPathExpand do
  @moduledoc """
  Release L's owner-run boot steps, the expand step of retiring
  `notes.path_*`. L still reads and writes every path column; these only
  make room for the releases that stop. Each is an `Engram.Release.BootStep`
  (ledger, flags-only kill switch, never fails boot), run by
  `Engram.Release.migrate/0` after the migrations, on the migrator
  connection, inside the migration lock: CREATE INDEX and ALTER TABLE need
  the table owner, which only that eval holds.

    * `notes_shape_relax` (flag `notes_shape_relax`): `notes_kind_shape_v5_check`
      lets a LIVE note carry a NULL `path_hmac` when it has a name address
      (`name_hmac` and `folder_ref_id`; a tombstone keeps its frozen path, so
      it still needs one). Added NOT VALID (ACCESS
      EXCLUSIVE for milliseconds, 5 s `lock_timeout`), VALIDATEd (SHARE
      UPDATE EXCLUSIVE, one heap scan, writes continue; it cannot fail: v4
      implies v5), then v4 dropped (ACCESS EXCLUSIVE, catalog only).
    * `notes_name_unique_build` (flag `notes_name_unique_build`, default
      OFF, see `steps/1`): UNIQUE
      `notes_name_live (vault_id, folder_ref_id, name_hmac)` on live notes,
      the collision guard that replaces the path's. Exact `name_hmac`, case
      sensitive as today's path guard is (`A.md` beside `a.md` is allowed).
      A duplicate probe runs first, through the maintenance credential (the
      migrator sees no rows under FORCE RLS); a duplicate logs its count at
      error and defers the build. The build's own unique check backs it: a
      unique violation defers too, and the failed build's INVALID index
      (which would still enforce uniqueness on writes) is dropped.
    * `notes_manifest_name_build` (flag `notes_manifest_name_build`):
      `notes_manifest_name (user_id, vault_id, id) INCLUDE (dek_version, seq,
      content_hash, folder_ref_id, name_ciphertext, name_nonce, name_stamp,
      path_nonce)` on live notes, so a later release can serve
      `GET /sync/manifest` from names index-only (`notes_manifest` carries the
      path instead). A name is one path segment, at most 255 bytes
      (`PathSanitizer`), so no entry nears the 2,704-byte btree limit and no
      length predicate is needed. `path_nonce` is included for the overlap,
      while a stamp may still be anchored on it (`Location.derivable?/1`).
      Partial on `name_stamp IS NOT NULL`, which only the names manifest
      states (verbatim, like `notes_manifest`'s length clause): without it
      this vault-led index carrying `folder_ref_id` won the moved-folder
      feed's per-folder legs as an index-only scan of the whole vault
      (`MovedFolderFeedPlanTest`), the tie class of
      docs/context/notes-generic-plan-mis-pick.md. Rows with a NULL
      `name_stamp` are not in it: the release that serves the manifest from
      names needs a second leg serving them by path (`notes_manifest`); they
      never fall back by themselves.

  Measured on a throwaway Postgres 18 at prod size (220k rows, 430 MB heap,
  OS cache warm, 2026-11-27): VALIDATE 0.4 s, probe 0.6-1.3 s, unique build
  0.8-1.3 s (17 MB), manifest build 1.1-1.4 s (43 MB). A build waits out
  older transactions with no `lock_timeout`, bounded by the boot steps'
  shared budget (`BootStep`); one that runs out of it, or is killed with its
  task, leaves an INVALID index that is dropped and rebuilt.

  Write cost: each index adds one entry per inserted or non-HOT updated
  live note (every save is already non-HOT, `seq` is indexed).
  """

  alias Engram.Logger.Metadata
  alias Engram.Release.BootStep
  alias Engram.Repo.Maintenance

  require Logger

  @live "deleted_at IS NULL AND kind = 'note'"

  @shape_v5 """
  ALTER TABLE notes ADD CONSTRAINT notes_kind_shape_v5_check CHECK (
    (kind = 'note'   AND (path_hmac IS NOT NULL OR (deleted_at IS NULL
                          AND name_hmac IS NOT NULL AND folder_ref_id IS NOT NULL))
                     AND title_ciphertext    IS NOT NULL
                     AND tags_ciphertext     IS NOT NULL)
    OR
    (kind = 'folder' AND path_hmac           IS NULL
                     AND title_ciphertext    IS NULL
                     AND tags_ciphertext     IS NULL
                     AND folder_hmac         IS NOT NULL)
  ) NOT VALID
  """

  @unique "notes_name_live"
  @unique_on "ON notes (vault_id, folder_ref_id, name_hmac) WHERE #{@live}"
  @unique_create "CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS #{@unique} #{@unique_on}"

  # Live notes sharing a folder row and an exact name: what the build refuses.
  @duplicates "SELECT count(*) FROM (SELECT 1 FROM notes WHERE #{@live} " <>
                "AND folder_ref_id IS NOT NULL AND name_hmac IS NOT NULL " <>
                "GROUP BY vault_id, folder_ref_id, name_hmac HAVING count(*) > 1) d"

  @manifest "notes_manifest_name"
  @manifest_create "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@manifest} " <>
                     "ON notes (user_id, vault_id, id) INCLUDE (dek_version, seq, " <>
                     "content_hash, folder_ref_id, name_ciphertext, name_nonce, name_stamp, " <>
                     "path_nonce) WHERE #{@live} AND name_stamp IS NOT NULL"

  @doc "The name collision guard's index (`Engram.Notes.PathUniques` lists it)."
  def unique_index, do: @unique

  @doc "Its definition after the name (`ON notes (...) WHERE ...`)."
  def unique_on, do: @unique_on

  @doc "The three steps, in order. `opts`: `:probe` (tests only)."
  @spec steps(keyword()) :: [BootStep.t()]
  def steps(opts \\ []) do
    [
      %BootStep{
        name: "notes_shape_relax",
        version: 1,
        flag: :notes_shape_relax,
        apply: &relax_shape/1
      },
      # The one step that ENFORCES something (writers map a violation the way
      # they map a path index's: `Engram.Notes.PathUniques`). It ships DARK
      # (`default: false`: it runs only once the flags file says true), because
      # today's S5 drift rows (a folder ref that disagrees with the stored
      # path, `Engram.Notes.LocationTest` "drift") may share a folder row and
      # name with a live note by design, and the index would refuse writes
      # those flows rely on. The release that retires drift turns it on.
      %BootStep{
        name: "notes_name_unique_build",
        version: 1,
        flag: :notes_name_unique_build,
        default: false,
        apply: &build_unique(&1, Keyword.get(opts, :probe, true))
      },
      %BootStep{
        name: "notes_manifest_name_build",
        version: 1,
        flag: :notes_manifest_name_build,
        apply: &BootStep.build_index(&1, @manifest, @manifest_create)
      }
    ]
  end

  defp relax_shape(session) do
    add = if constraint?(session.repo, "notes_kind_shape_v5_check"), do: [], else: [@shape_v5]

    BootStep.exec(
      session,
      add ++
        [
          "ALTER TABLE notes VALIDATE CONSTRAINT notes_kind_shape_v5_check",
          "ALTER TABLE notes DROP CONSTRAINT IF EXISTS notes_kind_shape_v4_check"
        ]
    )
  end

  defp constraint?(repo, name) do
    %{rows: rows} =
      repo.query!(
        "SELECT 1 FROM pg_constraint WHERE conrelid = 'public.notes'::regclass AND conname = $1",
        [name],
        log: false
      )

    rows != []
  end

  # `probe` false only in tests: the build's own unique check is the backstop
  # for a duplicate the probe did not see.
  defp build_unique(session, probe) do
    with :ok <- if(probe, do: probe(session), else: :ok) do
      case BootStep.build_index(session, @unique, @unique_create) do
        {:defer, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
          duplicates_found(:found_by_build)

        other ->
          other
      end
    end
  end

  defp probe(session) do
    if BootStep.index_state(session, @unique) == :valid do
      :ok
    else
      case duplicates(session) do
        {:ok, %{rows: [[0]]}} -> :ok
        {:ok, %{rows: [[n]]}} -> duplicates_found(n)
        {:error, e} -> {:defer, e}
      end
    end
  end

  # An error line (alertable) with the count: the build waits until the
  # duplicates are resolved by hand, and the ledger stays open.
  defp duplicates_found(count) do
    Logger.error(
      "notes_name_unique_build duplicates=#{count}; the unique build waits for them to be resolved",
      Metadata.with_category(:error, :boot, migration: "notes_name_unique_build")
    )

    {:defer, "duplicates=#{count}"}
  end

  # The migrator owns `notes` but is not a superuser, so FORCE RLS filters
  # every row it reads: in prod a probe on its session counts nothing. The
  # maintenance credential's `maintenance_all` policy sees every tenant, so
  # the probe runs there when it is configured (SaaS), on a one-connection
  # pool opened for it (the eval starts no app). Without it (self-host, whose
  # migrator is a superuser) it runs on the migrator session.
  defp duplicates(session) do
    left = session.deadline - System.monotonic_time(:millisecond)

    if Application.get_env(:engram, :maintenance_repo_enabled, false) and left >= 1_000 do
      with_maintenance(fn ->
        Maintenance.transaction(fn ->
          _ = Maintenance.query!("SET LOCAL statement_timeout = #{min(left, 30_000)}")
          Maintenance.query!(@duplicates, [], timeout: left + 5_000)
        end)
      end)
    else
      BootStep.query(session, @duplicates)
    end
  rescue
    e -> {:error, e}
  end

  # The running pool when there is one (a node, a test); else one connection
  # from the pool's config, for this probe only, stopped after it.
  defp with_maintenance(fun) do
    case Process.whereis(Maintenance) do
      nil ->
        {:ok, pid} = Maintenance.start_link(name: nil, pool_size: 1)

        try do
          _ = Maintenance.put_dynamic_repo(pid)
          fun.()
        after
          _ = Maintenance.put_dynamic_repo(Maintenance)
          Supervisor.stop(pid)
        end

      _pid ->
        fun.()
    end
  end
end
