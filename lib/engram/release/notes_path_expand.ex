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
      lets a LIVE note carry a NULL `path_hmac` (a tombstone keeps its
      frozen path, so it still needs one). Added NOT VALID (ACCESS
      EXCLUSIVE for milliseconds, 5 s `lock_timeout`), VALIDATEd (SHARE
      UPDATE EXCLUSIVE, one heap scan, writes continue; it cannot fail: v4
      implies v5), then v4 dropped (ACCESS EXCLUSIVE, catalog only).
    * `notes_name_unique_build` (flag `notes_name_unique_build`): UNIQUE
      `notes_name_live (vault_id, folder_ref_id, name_hmac)` on live notes,
      the collision guard that replaces the path's. Exact `name_hmac`, case
      sensitive as today's path guard is (`A.md` beside `a.md` is allowed).
      A duplicate probe runs first; a duplicate defers the build and logs
      its count. The probe reads through RLS, and the migrator role may see
      no rows under FORCE RLS, so the build's own unique check backs it: a
      unique violation is a deferral too, and the failed build's INVALID
      index (which would still enforce uniqueness on writes) is dropped.
    * `notes_manifest_name_build` (flag `notes_manifest_name_build`):
      `notes_manifest_name (user_id, vault_id, id) INCLUDE (dek_version, seq,
      content_hash, folder_ref_id, name_ciphertext, name_nonce, name_stamp,
      path_nonce)` on live notes, so a later release can serve
      `GET /sync/manifest` from names index-only (`notes_manifest` carries the
      path instead). A name is one path segment, at most 255 bytes
      (`PathSanitizer`), so no entry nears the 2,704-byte btree limit and no
      length predicate is needed. `path_nonce` is included for the overlap,
      while a stamp may still be anchored on it (`Location.derivable?/1`).

  Measured on a throwaway Postgres 18 at prod size (220k rows, 430 MB heap,
  OS cache warm, 2026-11-27): VALIDATE 0.4 s, probe 0.6-1.3 s, unique build
  0.8-1.3 s (17 MB), manifest build 1.1-1.4 s (43 MB). A build waiting out
  an old snapshot hits its `lock_timeout` and defers; a build killed with
  its task leaves an INVALID index the next boot drops and rebuilds.

  Write cost: each index adds one entry per inserted or non-HOT updated
  live note (every save is already non-HOT, `seq` is indexed).
  """

  alias Engram.Release.BootStep

  @live "deleted_at IS NULL AND kind = 'note'"

  @shape_v5 """
  ALTER TABLE notes ADD CONSTRAINT notes_kind_shape_v5_check CHECK (
    (kind = 'note'   AND (path_hmac IS NOT NULL OR deleted_at IS NULL)
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
  @unique_create "CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS #{@unique} " <>
                   "ON notes (vault_id, folder_ref_id, name_hmac) WHERE #{@live}"

  # Live notes sharing a folder row and an exact name: what the build refuses.
  @duplicates "SELECT count(*) FROM (SELECT 1 FROM notes WHERE #{@live} " <>
                "AND folder_ref_id IS NOT NULL AND name_hmac IS NOT NULL " <>
                "GROUP BY vault_id, folder_ref_id, name_hmac HAVING count(*) > 1) d"

  @manifest "notes_manifest_name"
  @manifest_create "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@manifest} " <>
                     "ON notes (user_id, vault_id, id) INCLUDE (dek_version, seq, " <>
                     "content_hash, folder_ref_id, name_ciphertext, name_nonce, name_stamp, " <>
                     "path_nonce) WHERE #{@live}"

  @doc "The three steps, in order."
  @spec steps(keyword()) :: [BootStep.t()]
  def steps(opts \\ []) do
    [
      %BootStep{
        name: "notes_shape_relax",
        version: 1,
        flag: :notes_shape_relax,
        apply: &relax_shape/1
      },
      %BootStep{
        name: "notes_name_unique_build",
        version: 1,
        flag: :notes_name_unique_build,
        apply: &build_unique(&1, Keyword.get(opts, :probe, true))
      },
      %BootStep{
        name: "notes_manifest_name_build",
        version: 1,
        flag: :notes_manifest_name_build,
        apply: fn repo ->
          BootStep.in_session(repo, fn ->
            BootStep.build_index(repo, @manifest, @manifest_create)
          end)
        end
      }
    ]
  end

  defp relax_shape(repo) do
    BootStep.in_session(repo, fn ->
      add = if constraint?(repo, "notes_kind_shape_v5_check"), do: [], else: [@shape_v5]

      BootStep.exec(
        repo,
        add ++
          [
            "ALTER TABLE notes VALIDATE CONSTRAINT notes_kind_shape_v5_check",
            "ALTER TABLE notes DROP CONSTRAINT IF EXISTS notes_kind_shape_v4_check"
          ]
      )
    end)
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

  # `probe` false only in tests: the path where the probe sees nothing
  # (FORCE RLS) and the build's own unique check catches the duplicate.
  defp build_unique(repo, probe) do
    BootStep.in_session(repo, fn ->
      with :ok <- if(probe, do: probe(repo), else: :ok) do
        case BootStep.build_index(repo, @unique, @unique_create) do
          {:defer, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
            {:defer, :duplicates_found_by_build}

          other ->
            other
        end
      end
    end)
  end

  defp probe(repo) do
    if BootStep.index_state(repo, @unique) == :valid do
      :ok
    else
      case BootStep.query(repo, @duplicates) do
        {:ok, %{rows: [[0]]}} -> :ok
        {:ok, %{rows: [[n]]}} -> {:defer, "duplicates=#{n}"}
        {:error, e} -> {:defer, e}
      end
    end
  end
end
