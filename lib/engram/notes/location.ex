defmodule Engram.Notes.Location do
  @moduledoc """
  Where a note is, read from its folder row and its own name (O(1) folder
  rename plan, S3 read switch, Engram#2523). The one module every by-path
  lookup and every derived output path goes through.

  A note row stores `folder_ref_id` plus its name (`Engram.Notes.Name`, S2).
  Writers still cascade in S3, so the STORED path stays the truth: it is
  what the plugin holds and what the unique `notes_path_live` slot names.
  With `on?/0`:

    * **by-path lookup** (`at/5`, `at_any/5`): ONE statement. A live note
      whose stored path key is the asked path is that path's note, always.
      Only in a vault holding a folder moved without a cascade (from S5 on,
      so never in S3 alone) and only when no row holds the path does the
      name answer: the folder part
      of the path is walked on `folders_live_name` (`Engram.Folders.WalkSql`,
      one unique-index probe per segment), then the note is probed on
      `notes_folder_name_live` by `(vault_id, name_ci_hmac || folder_ref_id)`
      with the exact `name_hmac` and a CURRENT name stamp as filters. Several
      such rows (drift) give the lowest id, never two rows. Cost: depth + 3
      index probes (the path key twice: the match and the no-holder check),
      never a scan of a folder or a vault.
    * **output paths** (`chains/1`, `put_paths/3`): a live note is shown where
      its folder row puts it ONLY when a folder on its chain was renamed
      without a cascade (`folders.notes_cascaded = false`, written from S5
      on: S3 as S5's rollback target). Any other row shows its stored path,
      drift included. One statement per batch, only in a vault holding such
      a folder (`folders_moved_live`, one probe otherwise); the feed page
      folds that probe into its own statement.

  A name is trusted only while `name_stamp == stamp(path_nonce)`
  (`Engram.Crypto.NameKeys`): the previous release (a rolling deploy, a
  rollback) rewrites the path without the name, which stales the stamp.
  Rows with no `folder_ref_id` (the root, or an unresolved folder) and
  tombstones are read and shown by their stored path. So S5 must give the
  root a row or keep writing `path_*` for rows with no folder ref.

  Gate (`on?/0`): the S2 `note_name` ledger is done (read from the ledger
  row, cached a minute per node, so `DataMigrations.reopen/2` turns names
  off within the minute) and the `name_reads` service override is not
  false (a kill switch, no deploy). Off, every function here answers exactly
  what the path read did.

  Not read here: `notes.folder_hmac` (release E stops writing it).
  """

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.Crypto.{Envelope, NameKeys, PathCrypto}
  alias Engram.DataMigrations.{Entry, NoteName}
  alias Engram.Folders.{Rows, WalkSql}
  alias Engram.Notes.{Helpers, Keys, Name, Note}
  alias Engram.Repo

  require NameKeys
  require WalkSql

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
    if on?, do: named(filter_key, vault_id, path, path_key, ids?), else: path_key
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

  defp named(filter_key, vault_id, path, path_key, ids?) do
    case path |> String.split("/") |> Enum.split(-1) do
      {[], _root} ->
        path_key

      {folders, [name]} ->
        segs = Enum.map(folders, &Rows.name_hmac(filter_key, &1))

        by_name =
          by_name(vault_id, segs, Name.ci_hmac(filter_key, name), Name.hmac(filter_key, name))

        live = from(m in Note, where: m.vault_id == ^vault_id and is_nil(m.deleted_at))

        # No row holds the path (the stored path wins while writers cascade).
        holder =
          from(p in live,
            where: p.kind == "note",
            where: ^path_key,
            where: ^Keys.kind_match(:note, ids?),
            select: p.id
          )

        # Of the rows the name matches, the lowest id: one row, never two.
        first =
          from(m in live,
            where: m.kind == "note",
            where: ^by_name,
            order_by: [asc: m.id],
            limit: 1,
            select: m.id
          )

        dynamic(
          [n],
          ^path_key or
            (^by_name and not exists(subquery(holder)) and n.id in subquery(first))
        )
    end
  end

  # The row's name key, folder and current stamp match: the folder walked
  # down from the root (`WalkSql.key_eq/0`, on `notes_folder_name_live`),
  # the exact name, a name whose stamp is current. Only in a vault holding a
  # folder moved without a cascade (`WalkSql.moved/0`, one probe of the
  # empty-until-S5 `folders_moved_live`): until S5 writes one, a name match
  # can only be drift, a row the user sees somewhere else, so every lookup,
  # push, delete and CRDT create reads stored paths exactly as 0.83.0 did.
  defp by_name(vault_id, segs, ci, exact) do
    dynamic(
      [n],
      fragment(
        WalkSql.key_eq(),
        n.name_ci_hmac,
        n.folder_ref_id,
        type(^ci, :binary),
        type(^vault_id, Ecto.UUID),
        type(^segs, {:array, :binary}),
        type(^vault_id, Ecto.UUID),
        type(^segs, {:array, :binary}),
        ^length(segs)
      ) and n.name_hmac == ^exact and
        fragment(NameKeys.current_sql(), n.name_stamp, n.path_nonce, ^Name.version()) and
        fragment(WalkSql.moved(), type(^vault_id, Ecto.UUID))
    )
  end

  @doc """
  The folder rows `put_paths/3` needs to show `rows` where their folders
  are: `Rows.chain_rows/3` (`moved_only`) for the folders of the rows
  `derivable?/1` picks, one statement per vault among them, reading nothing
  past one index probe unless the vault holds a folder moved without a
  cascade. Call it inside the tenant transaction that read `rows`; nil while
  names are off or no row has a folder.
  """
  @spec chains([map()]) :: [map()] | nil
  def chains(rows) do
    with true <- on?(),
         [_ | _] = rows <- Enum.filter(rows, &derivable?/1) do
      rows
      |> Enum.group_by(& &1.vault_id, & &1.folder_ref_id)
      |> Enum.flat_map(fn {vault_id, ids} ->
        Rows.chain_rows(vault_id, Enum.uniq(ids), moved_only: true)
      end)
    else
      _ -> nil
    end
  end

  @doc """
  The select extra a page query of `vault_id` carries so it needs no
  `chains/1` read while nothing in the vault moved (`moved?/1`): `%{}` with
  names off.
  """
  @spec moved_column(Ecto.UUID.t()) :: map()
  def moved_column(vault_id) do
    if on?(),
      do: %{moved__: dynamic(fragment(WalkSql.moved(), type(^vault_id, Ecto.UUID)))},
      else: %{}
  end

  @doc "Whether a page read with `moved_column/1` must read `chains/1`."
  @spec moved?([map()]) :: boolean()
  def moved?(rows), do: Enum.any?(rows, &(Map.get(&1, :moved__) == true))

  @doc """
  `%{id => path}`: where each row IS for the lookup that found it. A row
  `derivable?/1` gets its folder's path plus its name (one chain read, in
  its own tenant block unless the caller is in one); any other row, or one
  whose name or chain does not open, its stored path: the decrypted `:path`
  it carries, else its `path_ciphertext` decrypted here. Rows are notes of
  one user, from any of their vaults.
  """
  @spec paths(map(), [map()]) :: %{Ecto.UUID.t() => String.t() | nil}
  def paths(_user, []), do: %{}

  def paths(user, rows) do
    dek =
      case Crypto.get_dek(user) do
        {:ok, dek} -> dek
        _ -> nil
      end

    named = Enum.filter(rows, &derivable?/1)

    derived =
      if dek && named != [] and on?() do
        chains =
          Repo.with_tenant!(user.id, fn ->
            named
            |> Enum.group_by(& &1.vault_id, & &1.folder_ref_id)
            |> Enum.flat_map(fn {vault_id, ids} -> Rows.chain_rows(vault_id, Enum.uniq(ids)) end)
          end)

        derive(dek, named, &Rows.chain_paths(dek, chains, &1))
      else
        %{}
      end

    Map.new(rows, &{&1.id, Map.get_lazy(derived, &1.id, fn -> stored(&1, dek) end)})
  end

  @doc """
  `notes` (decrypted `%Note{}`s of one user) with `path` and `folder` set to
  where their folder rows put them, for the notes under a folder moved
  without a cascade (`chains/1`'s result, read with the notes; `:read`
  reads it here). Every other note keeps its stored path.
  """
  @spec put_paths(map(), [struct()], [map()] | nil | :read) :: [struct()]
  def put_paths(user, notes, chains \\ :read)
  def put_paths(_user, [], _chains), do: []

  def put_paths(user, notes, chains) do
    chains =
      if chains == :read and on?(),
        do: Repo.with_tenant!(user.id, fn -> chains(notes) end),
        else: chains

    with [_ | _] <- chains,
         {:ok, dek} <- Crypto.get_dek(user) do
      moved = derive(dek, Enum.filter(notes, &derivable?/1), &Rows.moved_paths(dek, chains, &1))

      Enum.map(notes, fn note ->
        case Map.fetch(moved, note.id) do
          {:ok, path} -> %{note | path: path, folder: Helpers.extract_folder(path)}
          :error -> note
        end
      end)
    else
      _ -> notes
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
      is_binary(row.path_nonce) and row.name_stamp == NameKeys.stamp(row.path_nonce)
  end

  # `rows`' folder paths (`folder_paths`, given their folder ids) joined
  # with their decrypted names; a row whose folder has no path there is left
  # out (it keeps its stored path).
  defp derive(_dek, [], _folder_paths), do: %{}

  defp derive(dek, rows, folder_paths) do
    folders = folder_paths.(rows |> Enum.map(& &1.folder_ref_id) |> Enum.uniq())

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
end
