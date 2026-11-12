defmodule Engram.Notes.Location do
  @moduledoc """
  Where a note is, read from its folder row and its own name (O(1) folder
  rename plan, S3 read switch, Engram#2523). The one module every by-path
  lookup and every derived output path goes through.

  A note row stores `folder_ref_id` plus its name (`Engram.Notes.Name`, S2).
  With `on?/0`:

    * **by-path lookup** (`at/5`, `at_any/5`): ONE statement. The folder part
      of the path is walked on `folders_live_name` (one unique-index probe
      per segment, a recursive CTE in a scalar subquery), then the note is
      probed on `notes_folder_name_live` by `(vault_id, name_ci_hmac ||
      folder_ref_id)` with the exact `name_hmac` as a filter. A row whose name
      cannot be trusted is matched by its stored path key instead (see
      below), in an OR the planner serves as a BitmapOr of the two indexes.
      Cost: depth + 2 index probes, never a scan of a folder or a vault.
    * **output paths** (`paths/2`, `put_paths/2`): a live row's path is its
      folder's path (`Engram.Folders.Rows.paths_by_ids/3`, one recursive
      read for a batch's distinct folders) joined with its decrypted name.
      Cost per batch of K rows: 1 statement reading at most the distinct
      ancestors of the rows' folders, K name decrypts in one native call.

  Which rows are read by name: live, with a `folder_ref_id`, and a CURRENT
  name (`name_stamp == stamp(path_nonce)`). Every other row is read by its
  stored path, as before S3:

    * a stale stamp: the previous release (a rolling deploy, a rollback)
      rewrote the path without the name, so the path is the newer truth;
    * no `folder_ref_id`: NULL means the root OR an unresolved folder
      (drift), and only the stored path tells them apart. So root notes are
      read by path in S3; S5 must either give the root a row or keep
      writing `path_*` for rows with no folder ref;
    * tombstones and trashed rows: they keep the path they were deleted at
      (the feed's #614 tombstones carry the OLD path on purpose).

  Writers still cascade in S3, so the stored path and the derived one agree
  for every row; `put_paths/2` logs a count when they do not (never a path).
  The point of reading names now: S5 stops the cascade, and S3 is its
  rollback target, so S3 must already find and show a note where its folder
  row says it is.

  Gate (`on?/0`): the S2 `note_name` ledger is done (read from the ledger
  row, cached a minute per node, so `DataMigrations.reopen/2` turns names
  off within the minute) and the `name_reads` service override is not
  false (a kill switch, no deploy). Off, every function here answers exactly
  what the path read did.

  Not read here: `notes.folder_hmac` (release E stops writing it).
  """

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.Crypto.{Envelope, PathCrypto}
  alias Engram.DataMigrations.{Entry, NoteName}
  alias Engram.Folders.Rows
  alias Engram.Logger.Metadata
  alias Engram.Notes.{Helpers, Keys, Name}
  alias Engram.Repo

  require Logger

  @doc "The columns `paths/2` reads from a row, beside `id`, `vault_id`, `deleted_at` and the path."
  @spec fields() :: [:folder_ref_id | :name_ciphertext | :name_nonce | :name_stamp, ...]
  def fields, do: [:folder_ref_id, :name_ciphertext, :name_nonce, :name_stamp]

  @doc "Whether readers use names (the `note_name` ledger is done, `name_reads` not off)."
  @spec on?() :: boolean()
  def on?, do: Engram.ServiceConfig.get(:name_reads, true) == true and ledger_done?()

  # Read from the ledger row itself, not `NoteName.done?/0`, whose `true` is
  # kept for the node's lifetime (`Engram.Notes.Keys.ids?/0` does the same).
  # `:name_reads_ledger` is unset in prod (the row is read); the test suite
  # sets `:done`, prod's state, since its DB never completes the ledger
  # (`config/test.exs`).
  defp ledger_done? do
    Engram.ServiceConfig.get(:name_reads_ledger, :read) == :done or ledger_row_done?()
  end

  defp ledger_row_done? do
    Engram.Cache.fetch(:note_name, :done, fn ->
      Repo.exists?(
        from(e in Entry,
          where:
            e.name == ^NoteName.name() and e.version >= ^NoteName.version() and
              not is_nil(e.completed_at)
        )
      )
    end)
  end

  @doc """
  The filter for the live note at `path` (sanitized) in `vault_id`, under
  the user's `filter_key`. `ids?` and `on?` are read once by the caller, so
  the filter and the partial-index predicates agree.
  """
  @spec at(binary(), Ecto.UUID.t(), String.t(), boolean(), boolean()) ::
          Ecto.Query.dynamic_expr()
  def at(filter_key, vault_id, path, ids? \\ Keys.ids?(), on? \\ on?()) do
    path_key = Keys.eq(:path, Crypto.hmac_field(filter_key, path), ids?)
    if on?, do: named(filter_key, vault_id, path, path_key), else: path_key
  end

  @doc "`at/5` for any of `paths` (a few dozen at most: one walk per path)."
  @spec at_any(binary(), Ecto.UUID.t(), [String.t()], boolean(), boolean()) ::
          Ecto.Query.dynamic_expr()
  def at_any(filter_key, vault_id, paths, ids? \\ Keys.ids?(), on? \\ on?())

  def at_any(filter_key, _vault_id, paths, ids?, false),
    do: Keys.in_any(:path, Enum.map(paths, &Crypto.hmac_field(filter_key, &1)), ids?)

  def at_any(filter_key, vault_id, paths, ids?, true) do
    paths
    |> Enum.uniq()
    |> Enum.map(&at(filter_key, vault_id, &1, ids?, true))
    |> Enum.reduce(dynamic(false), &dynamic(^&2 or ^&1))
  end

  defp named(filter_key, vault_id, path, path_key) do
    # The stored path answers for a row whose name it cannot trust.
    by_path = dynamic([n], ^path_key and (is_nil(n.folder_ref_id) or ^stale()))

    case path |> String.split("/") |> Enum.split(-1) do
      {[], _root} ->
        by_path

      {folders, [name]} ->
        segs = Enum.map(folders, &Rows.name_hmac(filter_key, &1))
        ci = Name.ci_hmac(filter_key, name)
        exact = Name.hmac(filter_key, name)

        dynamic(
          [n],
          (^in_folder(vault_id, segs, ci) and n.name_hmac == ^exact and ^current()) or ^by_path
        )
    end
  end

  # The row's `(name_ci_hmac, folder_ref_id)` key, as `notes_folder_name_live`
  # indexes it (one bytea, so no read by folder alone can use that index),
  # equals `ci` plus the live folder at the end of `segs` (name hmacs, root
  # first). The folder is one probe of `folders_live_name` per level
  # (unique, so at most one row a level, and the scalar subquery never sees
  # two; none gives NULL, which matches nothing). Each level is a LATERAL
  # probe keyed by the level above, so the planner cannot hash-join a whole
  # vault's folders per level. Uncorrelated, so it runs once (an InitPlan)
  # and the key is an index condition for the notes probe. It reads
  # `folders` in the statement's own tenant (FORCE RLS).
  defp in_folder(vault_id, segs, ci) do
    dynamic(
      [n],
      fragment(
        """
        (? || uuid_send(?)) = (? || uuid_send((WITH RECURSIVE w(i, id) AS (
           SELECT 1, f.id FROM folders f
           WHERE f.vault_id = ? AND f.parent_id IS NULL AND f.name_hmac = (?)[1]
             AND f.deleted_at IS NULL
           UNION ALL
           SELECT w.i + 1, c.id FROM w CROSS JOIN LATERAL (
             SELECT f.id FROM folders f
             WHERE f.vault_id = ? AND f.parent_id = w.id AND f.name_hmac = (?)[w.i + 1]
               AND f.deleted_at IS NULL
             LIMIT 1
           ) c
         ) SELECT w.id FROM w WHERE w.i = ?)))
        """,
        n.name_ci_hmac,
        n.folder_ref_id,
        type(^ci, :binary),
        type(^vault_id, Ecto.UUID),
        type(^segs, {:array, :binary}),
        type(^vault_id, Ecto.UUID),
        type(^segs, {:array, :binary}),
        ^length(segs)
      )
    )
  end

  defp current,
    do:
      dynamic(
        [n],
        fragment("? = (? || ?)", n.name_stamp, n.path_nonce, type(^Name.version(), :binary))
      )

  defp stale,
    do:
      dynamic(
        [n],
        fragment(
          "? IS DISTINCT FROM (? || ?)",
          n.name_stamp,
          n.path_nonce,
          type(^Name.version(), :binary)
        )
      )

  @doc """
  The folder rows `paths/3` needs to derive `rows`' paths: `Rows.chain_rows/2`
  for the folders of the rows `derivable?/1` picks, ONE read per vault among
  them. Call it inside the tenant transaction that read `rows` (no extra
  transaction); nil while names are off or no row needs a folder.
  """
  @spec chains([map()]) :: [map()] | nil
  def chains(rows) do
    with true <- on?(),
         [_ | _] = rows <- Enum.filter(rows, &derivable?/1) do
      rows
      |> Enum.group_by(& &1.vault_id, & &1.folder_ref_id)
      |> Enum.flat_map(fn {vault_id, ids} -> Rows.chain_rows(vault_id, Enum.uniq(ids)) end)
    else
      _ -> nil
    end
  end

  @doc """
  `%{id => path}`: each row's current path. A row `derivable?/1` gets its
  folder's path plus its name; any other row (or one whose name or folder
  chain does not open) its stored path: the decrypted `:path` it carries, else
  its `path_ciphertext` decrypted here. Rows are notes of one user, from any
  of their vaults.

  `chains`: `chains/1`'s result, read with the rows; `:read` reads it here
  (one statement, in its own tenant block unless the caller is in one). nil:
  stored paths only (names off).
  """
  @spec paths(map(), [map()], [map()] | nil | :read) :: %{Ecto.UUID.t() => String.t() | nil}
  def paths(user, rows, chains \\ :read)
  def paths(_user, [], _chains), do: %{}

  def paths(user, rows, chains) do
    dek =
      case Crypto.get_dek(user) do
        {:ok, dek} -> dek
        _ -> nil
      end

    chains = if chains == :read, do: read_chains(user, rows), else: chains

    derived =
      if dek && is_list(chains),
        do: derive(dek, Enum.filter(rows, &derivable?/1), chains),
        else: %{}

    Map.new(rows, &{&1.id, Map.get_lazy(derived, &1.id, fn -> stored(&1, dek) end)})
  end

  defp read_chains(user, rows) do
    if on?() and Enum.any?(rows, &derivable?/1),
      do: Repo.with_tenant!(user.id, fn -> chains(rows) end)
  end

  @doc """
  `notes` (decrypted `%Note{}`s of one user) with `path` and `folder` set to
  their current location (`paths/3`; `chains` as there). Logs how many
  derived paths differ from the stored ones: writers still cascade in S3,
  so any is drift (or a folder renamed since the rows were read).
  """
  @spec put_paths(map(), [struct()], [map()] | nil | :read) :: [struct()]
  def put_paths(user, notes, chains \\ :read)
  def put_paths(_user, [], _chains), do: []

  def put_paths(user, notes, chains) do
    if on?() do
      paths = paths(user, notes, chains)

      {notes, moved} =
        Enum.map_reduce(notes, 0, fn note, moved ->
          case paths[note.id] do
            path when path == note.path or not is_binary(path) ->
              {note, moved}

            path ->
              {%{note | path: path, folder: Helpers.extract_folder(path)}, moved + 1}
          end
        end)

      if moved > 0, do: log_moved(user, moved, length(notes))
      notes
    else
      notes
    end
  end

  @doc """
  `note`, found by `at/5` at `path`, shown at that path: the folder chain
  and the name it matched ARE its location, whatever its stored path still
  says. (Found by its path key, the two are the same path.)
  """
  @spec found_at(struct(), String.t()) :: struct()
  def found_at(%{path: path} = note, path), do: note
  def found_at(note, path), do: %{note | path: path, folder: Helpers.extract_folder(path)}

  @doc """
  The feed's additive fields for a live note while `on?/0`: its `folder_id`
  (nil at the root or when unresolved) and its `name` (the last segment of
  the path it is served at). Off, or a tombstone: none.
  """
  @spec wire_fields(struct(), boolean()) :: map()
  def wire_fields(%{deleted_at: nil, path: path} = note, true) when is_binary(path),
    do: %{folder_id: note.folder_ref_id, name: Name.of_path(path)}

  def wire_fields(_note, _on?), do: %{}

  @doc "Whether `row`'s location comes from its folder row and name (see the moduledoc)."
  @spec derivable?(map()) :: boolean()
  def derivable?(row) do
    is_nil(row.deleted_at) and is_binary(row.folder_ref_id) and is_binary(row.name_ciphertext) and
      is_binary(row.path_nonce) and row.name_stamp == Name.stamp(row.path_nonce)
  end

  defp derive(_dek, [], _chains), do: %{}

  defp derive(dek, rows, chains) do
    folders = Rows.chain_paths(dek, chains, rows |> Enum.map(& &1.folder_ref_id) |> Enum.uniq())

    for {row, {:ok, name}} <- Enum.zip(rows, decrypt_names(dek, rows)),
        folder = folders[row.folder_ref_id],
        into: %{},
        do: {row.id, folder <> "/" <> name}
  end

  # One native call for the batch (`Envelope.decrypt_many/3`); it is
  # all-or-nothing, so a row that will not open sends the batch through the
  # per-row decrypt, which fails just that row (it falls back to its path).
  defp decrypt_names(dek, rows) do
    fields =
      Enum.map(rows, &{Ecto.UUID.dump!(&1.id), true, &1.name_ciphertext, &1.name_nonce})

    case Envelope.decrypt_many(dek, Crypto.aad_prefix(:notes, :name), fields) do
      {:ok, names} ->
        Enum.map(names, &{:ok, &1})

      :error ->
        Enum.map(rows, &Name.decrypt(:notes, dek, &1.id, &1.name_ciphertext, &1.name_nonce))
    end
  end

  defp stored(%{path: path}, _dek) when is_binary(path), do: path
  defp stored(%{path_ciphertext: nil}, _dek), do: nil
  defp stored(_row, nil), do: nil

  defp stored(row, dek) do
    case Envelope.decrypt(
           row.path_ciphertext,
           row.path_nonce,
           dek,
           PathCrypto.aad(:notes, row.id, row.dek_version)
         ) do
      {:ok, path} -> path
      :error -> nil
    end
  end

  defp log_moved(user, moved, total) do
    Logger.warning(
      "note path derived from folder and name differs from the stored path",
      Metadata.with_category(:warning, :sync,
        user_id: user.id,
        failed_count: moved,
        total_count: total
      )
    )
  end
end
