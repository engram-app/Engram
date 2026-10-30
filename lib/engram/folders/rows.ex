defmodule Engram.Folders.Rows do
  @moduledoc """
  The one place that reads and writes `folders` rows (migration 20261029000000):
  key derivation, name encryption, find-or-create of a path, subtree lookups,
  rename, soft delete and restore.

  Every function that touches the table MUST run inside the caller's
  `Repo.with_tenant/2` (the table has FORCE row security). Writers call
  `ensure/4` inside the transaction that writes the note or attachment, so the
  row exists when the `notes_set_folder_ref` trigger looks it up and the
  composite foreign key checks it.

  Names are one path SEGMENT, encrypted under the account's per-user DEK with
  AAD `Crypto.aad_for_row(:folders, :name, id)` (the key scheme of
  `notes.folder_ciphertext`). `name_hmac` lives in its own domain so a segment
  hash never equals a `path_hmac`. `full_path_hmac` is the HMAC of the whole
  path and equals `notes.folder_hmac`: it is what the trigger and the
  previous release's rows join on, and it is rewritten for a renamed subtree.

  The stored paths (`notes.path_*` / `folder_*`, attachment `path_*`) stay
  authoritative and are still written everywhere; a folder row is a second,
  derived key (see `Engram.DataMigrations.FolderTable`, which heals whatever
  the previous release wrote).
  """

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Folders.Folder
  alias Engram.Repo

  # ---- keys and names (pure) ----------------------------------------------

  @doc "HMAC of one path segment, in the folder-name domain."
  @spec name_hmac(binary(), String.t()) :: binary()
  defdelegate name_hmac(filter_key, segment), to: Folder

  @doc "HMAC of a whole folder path: the value `notes.folder_hmac` holds."
  @spec path_hmac(binary(), String.t()) :: binary()
  def path_hmac(filter_key, path), do: Crypto.hmac_field(filter_key, path)

  @doc "Encrypts a segment for the folder row `id` (a canonical UUID string)."
  @spec encrypt_name(binary(), String.t(), String.t()) :: {binary(), binary()}
  def encrypt_name(dek, id, segment),
    do: Envelope.encrypt(segment, dek, Crypto.aad_for_row(:folders, :name, id))

  @doc "Decrypts a folder row's name. `{:ok, segment} | :error`."
  @spec decrypt_name(binary(), String.t(), integer(), binary(), binary()) ::
          {:ok, String.t()} | :error
  def decrypt_name(dek, id, dek_version, ct, nonce) do
    aad =
      if Crypto.aad_bound?(dek_version), do: Crypto.aad_for_row(:folders, :name, id), else: <<>>

    Envelope.decrypt(ct, nonce, dek, aad)
  end

  @doc "Every ancestor path of `path`, shallowest first, `path` itself last."
  @spec prefixes(String.t()) :: [String.t()]
  def prefixes(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.scan(fn seg, acc -> acc <> "/" <> seg end)
  end

  # ---- find-or-create ------------------------------------------------------

  @doc """
  Finds or creates the live folder row for `folder` ("A/B/C") in `vault_id`,
  creating missing ancestors, and returns the leaf's id. The root ("") has no
  row: `{:ok, nil}`.

  Safe against a concurrent creator: every insert is `ON CONFLICT DO NOTHING`
  (no error, so no aborted transaction, no savepoint needed) and a lost race
  is resolved by reading the winner's row. Call it from a transaction that
  holds no other lock a second creator could wait on, in a stable order
  (`ensure_all/3` sorts).

  Options: `explicit: marker_id` makes the leaf an explicit folder that keeps
  the marker's UUID (the backfill's rule); an existing live row is marked
  explicit and keeps its own id.
  """
  @spec ensure(map(), Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, Ecto.UUID.t() | nil} | {:error, term()}
  def ensure(user, vault_id, folder, opts \\ [])
  def ensure(_user, _vault_id, "", _opts), do: {:ok, nil}

  def ensure(user, vault_id, folder, opts) do
    with {:ok, dek} <- Crypto.get_dek(user),
         {:ok, fk} <- Crypto.dek_filter_key(user) do
      ctx = %{user_id: user.id, vault_id: vault_id, dek: dek, fk: fk}
      explicit = Keyword.get(opts, :explicit)
      {:ok, resolve_all(ctx, %{folder => explicit})[folder]}
    end
  end

  # Both entry points below are `ensure/4` for a set: one code path, set-based.
  defp ensure_set(user, vault_id, targets) do
    targets = Map.delete(targets, "")

    if map_size(targets) == 0 do
      {:ok, %{}}
    else
      with {:ok, dek} <- Crypto.get_dek(user),
           {:ok, fk} <- Crypto.dek_filter_key(user) do
        ctx = %{user_id: user.id, vault_id: vault_id, dek: dek, fk: fk}
        {:ok, resolve_all(ctx, targets)}
      end
    end
  end

  @doc """
  `ensure/4` for many folders: `{:ok, %{folder => id}}`, in a fixed number of
  statements (one read of every path and ancestor, one insert per depth
  level). Rows go in sorted, so two concurrent batches create shared
  ancestors in the same order and cannot deadlock on each other's
  unique-index entries.
  """
  @spec ensure_all(map(), Ecto.UUID.t(), [String.t()]) ::
          {:ok, %{String.t() => Ecto.UUID.t() | nil}} | {:error, term()}
  def ensure_all(user, vault_id, folders) do
    with {:ok, ids} <- ensure_set(user, vault_id, Map.new(folders, &{&1, nil})) do
      {:ok, Map.new(folders, &{&1, Map.get(ids, &1)})}
    end
  end

  @doc """
  Makes each `{folder, marker_id}` an explicit folder keeping the marker's UUID
  (see the `explicit:` option of `ensure/4`). Sorted for the reason
  `ensure_all/3` is.
  """
  @spec ensure_markers(map(), Ecto.UUID.t(), [{String.t(), Ecto.UUID.t()}]) :: :ok
  def ensure_markers(user, vault_id, markers) do
    targets =
      markers
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reverse()
      |> Map.new()

    {:ok, _} = ensure_set(user, vault_id, targets)
    :ok
  end

  # `targets`: %{folder => marker id | nil}. Returns %{folder => leaf id}.
  # One read of every prefix, then one insert per depth level (parents first).
  defp resolve_all(ctx, targets) do
    paths = targets |> Map.keys() |> Enum.flat_map(&prefixes/1) |> Enum.uniq()
    hmacs = Map.new(paths, &{&1, path_hmac(ctx.fk, &1)})
    known = live_ids_by_path_hmac(ctx.vault_id, Map.values(hmacs))
    ids = Map.new(paths, &{&1, Map.get(known, hmacs[&1])})

    ids =
      paths
      |> Enum.filter(&is_nil(ids[&1]))
      |> Enum.group_by(&length(String.split(&1, "/")))
      |> Enum.sort()
      |> Enum.reduce(ids, fn {_depth, level}, ids ->
        create_level(ctx, Enum.sort(level), ids, targets, hmacs)
      end)

    # A row that was already there becomes explicit when a marker names it.
    to_mark =
      for {folder, marker} <- targets, marker, Map.has_key?(known, hmacs[folder]), do: ids[folder]

    mark_explicit(to_mark)

    Map.new(targets, fn {folder, _} -> {folder, ids[folder]} end)
  end

  # Inserts the missing rows of one depth in one statement per chunk. A row the
  # insert did not write (a racing creator, a marker id that names a row
  # elsewhere) goes through `step/5`, which reads, repairs or moves it.
  defp create_level(ctx, level, ids, targets, hmacs) do
    rows =
      Enum.map(level, fn path ->
        parent = ids[parent_path(path)]
        marker = Map.get(targets, path)
        segment = path |> String.split("/") |> List.last()
        id = marker || mint_id()

        {path, parent, marker, id,
         build_row(ctx, id, parent, segment, hmacs[path], marker != nil)}
      end)

    written =
      rows
      |> Enum.chunk_every(1_000)
      |> Enum.flat_map(fn chunk ->
        {_, ret} =
          Repo.insert_all(Folder, Enum.map(chunk, &elem(&1, 4)),
            on_conflict: :nothing,
            returning: [:id]
          )

        Enum.map(ret, & &1.id)
      end)
      |> MapSet.new()

    Enum.reduce(rows, ids, fn {path, parent, marker, id, _row}, ids ->
      if MapSet.member?(written, id),
        do: Map.put(ids, path, id),
        else: Map.put(ids, path, step(ctx, parent, path, marker, 3, false))
    end)
  end

  defp parent_path(path) do
    case String.split(path, "/") do
      [_only] -> nil
      segments -> segments |> Enum.drop(-1) |> Enum.join("/")
    end
  end

  defp live_ids_by_path_hmac(_vault_id, []), do: %{}

  defp live_ids_by_path_hmac(vault_id, hmacs) do
    from(f in Folder,
      where: f.vault_id == ^vault_id and f.full_path_hmac in ^hmacs and is_nil(f.deleted_at),
      select: {f.full_path_hmac, f.id}
    )
    |> Repo.all()
    |> Map.new()
  end

  # One level: the live row for `path` under `parent_id`, created if absent.
  # The insert goes first (DO NOTHING), so the common case, a folder that is not
  # there yet, costs one statement; a row that is already there (found by the
  # live-name index, or one a racing creator just committed) is read after.
  defp step(ctx, parent_id, path, explicit, attempts, insert? \\ true) do
    segment = path |> String.split("/") |> List.last()
    name_h = name_hmac(ctx.fk, segment)
    full_h = path_hmac(ctx.fk, path)
    id = explicit || mint_id()

    case if(insert?,
           do: insert(ctx, id, parent_id, segment, full_h, explicit != nil),
           else: 0
         ) do
      1 ->
        id

      0 ->
        case live_child(ctx.vault_id, parent_id, name_h) do
          %{id: found} = row ->
            repair(row, full_h, explicit)
            found

          # No live row, yet the insert wrote nothing: `explicit` names a row
          # that exists elsewhere (tombstoned, or moved). Move it here, retry.
          nil when attempts > 0 ->
            revive_or_retry(ctx, explicit, parent_id, segment, name_h, full_h)
            step(ctx, parent_id, path, explicit, attempts - 1)

          nil ->
            raise "folders: could not find or create #{inspect(path)} after retries"
        end
    end
  end

  # The live rows named `name_h` under `parent_id` (at most one: the unique index).
  defp siblings(vault_id, parent_id, name_h) do
    query = from(f in Folder, where: f.vault_id == ^vault_id and f.name_hmac == ^name_h)

    if parent_id,
      do: where(query, [f], f.parent_id == ^parent_id and is_nil(f.deleted_at)),
      else: where(query, [f], is_nil(f.parent_id) and is_nil(f.deleted_at))
  end

  defp live_child(vault_id, parent_id, name_h) do
    Repo.one(
      from(f in siblings(vault_id, parent_id, name_h),
        select: %{id: f.id, full: f.full_path_hmac, explicit: f.explicit}
      )
    )
  end

  # A row another writer made may lack `full_path_hmac` (the previous release's
  # backfill gap) or the explicit flag: set what this caller knows.
  defp repair(%{id: id, full: full, explicit: explicit?}, full_h, marker) do
    if full != full_h or (marker && !explicit?) do
      from(f in Folder, where: f.id == ^id)
      |> Repo.update_all(
        set: [full_path_hmac: full_h, explicit: explicit? or marker != nil, updated_at: now()]
      )
    end

    :ok
  end

  defp mark_explicit([]), do: :ok

  defp mark_explicit(ids) do
    from(f in Folder, where: f.id in ^ids and not f.explicit)
    |> Repo.update_all(set: [explicit: true, updated_at: now()])

    :ok
  end

  defp build_row(ctx, id, parent_id, segment, full_h, explicit?) do
    {ct, nonce} = encrypt_name(ctx.dek, id, segment)
    now = now()

    %{
      id: id,
      user_id: ctx.user_id,
      vault_id: ctx.vault_id,
      parent_id: parent_id,
      name_ciphertext: ct,
      name_nonce: nonce,
      name_hmac: name_hmac(ctx.fk, segment),
      full_path_hmac: full_h,
      dek_version: Crypto.row_version_aad_bound(),
      explicit: explicit?,
      inserted_at: now,
      updated_at: now
    }
  end

  defp insert(ctx, id, parent_id, segment, full_h, explicit?) do
    {n, _} =
      Repo.insert_all(Folder, [build_row(ctx, id, parent_id, segment, full_h, explicit?)],
        on_conflict: :nothing
      )

    n
  end

  # An insert that wrote nothing hit the live-name index (the next `step` read
  # finds that row) or the primary key: a marker's UUID already names a row,
  # tombstoned or at another place. Move it here.
  defp revive_or_retry(_ctx, nil, _parent_id, _segment, _name_h, _full_h), do: :ok

  defp revive_or_retry(ctx, id, parent_id, segment, name_h, full_h) do
    {ct, nonce} = encrypt_name(ctx.dek, id, segment)

    free = siblings(ctx.vault_id, parent_id, name_h) |> where([f], f.id != ^id)

    from(f in Folder,
      where: f.id == ^id and f.vault_id == ^ctx.vault_id and not exists(subquery(free))
    )
    |> Repo.update_all(
      set: [
        parent_id: parent_id,
        name_ciphertext: ct,
        name_nonce: nonce,
        name_hmac: name_h,
        full_path_hmac: full_h,
        dek_version: Crypto.row_version_aad_bound(),
        explicit: true,
        deleted_at: nil,
        delete_op_id: nil,
        updated_at: now()
      ]
    )

    :ok
  end

  # ---- subtree -------------------------------------------------------------

  @doc """
  The live folder rows at `folders` and every live descendant, shallowest
  first, as `Folder` structs (names still encrypted). The recursive walk is
  over folder rows only, so its cost is the number of folders, never notes.
  """
  @spec subtree(map(), Ecto.UUID.t(), [String.t()]) :: [Folder.t()]
  def subtree(user, vault_id, folders) do
    case Crypto.dek_filter_key(user) do
      {:ok, fk} ->
        folders
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&path_hmac(fk, &1))
        |> then(&subtree_query(vault_id, &1))
        |> Repo.all()
        |> Enum.uniq_by(& &1.id)

      {:error, _} ->
        []
    end
  end

  @doc "`subtree/3`'s ids and path hashes only: what a reader joins notes on."
  @spec subtree_refs(map(), Ecto.UUID.t(), [String.t()]) :: [
          %{id: Ecto.UUID.t(), full_path_hmac: binary() | nil}
        ]
  def subtree_refs(user, vault_id, folders) do
    case Crypto.dek_filter_key(user) do
      {:ok, fk} ->
        roots = folders |> Enum.reject(&(&1 == "")) |> Enum.map(&path_hmac(fk, &1))

        from(f in subtree_query(vault_id, roots),
          select: %{id: f.id, full_path_hmac: f.full_path_hmac}
        )
        |> Repo.all()
        |> Enum.uniq_by(& &1.id)

      {:error, _} ->
        []
    end
  end

  @doc "The ids of the live rows at exactly `folders` (no descendants)."
  @spec ids_at(map(), Ecto.UUID.t(), [String.t()]) :: [Ecto.UUID.t()]
  def ids_at(user, vault_id, folders) do
    case Crypto.dek_filter_key(user) do
      {:ok, fk} ->
        hmacs = folders |> Enum.reject(&(&1 == "")) |> Enum.map(&path_hmac(fk, &1))

        from(f in Folder,
          where: f.vault_id == ^vault_id and f.full_path_hmac in ^hmacs and is_nil(f.deleted_at),
          select: f.id
        )
        |> Repo.all()

      {:error, _} ->
        []
    end
  end

  defp subtree_query(_vault_id, []), do: from(f in Folder, where: false)

  # A cycle in `parent_id` (never written by this module, but a bad row from any
  # path must not pin a connection in an endless recursion) is cut at this depth.
  @max_depth 512

  defp subtree_query(vault_id, root_hmacs) do
    roots =
      from(f in Folder,
        where:
          f.vault_id == ^vault_id and f.full_path_hmac in ^root_hmacs and is_nil(f.deleted_at),
        select: %{id: f.id, depth: fragment("0")}
      )

    walk =
      from(f in Folder,
        join: t in "folder_subtree",
        on: f.parent_id == t.id,
        where: f.vault_id == ^vault_id and is_nil(f.deleted_at) and t.depth < @max_depth,
        select: %{id: f.id, depth: fragment("? + 1", t.depth)}
      )

    from(f in Folder,
      join: t in "folder_subtree",
      on: f.id == t.id,
      order_by: [asc: t.depth, asc: f.id]
    )
    |> recursive_ctes(true)
    |> with_cte("folder_subtree", as: ^union_all(roots, ^walk))
  end

  # ---- rename --------------------------------------------------------------

  @doc """
  Renames the folder row at `old_folder` to `new_folder` (a rename or a move:
  any new parent) and rewrites `full_path_hmac` for the whole subtree.

  Costs the DESCENDANT FOLDERS, never notes: a note joins its folder by id, so
  the notes under it need no change (their stored paths are rewritten by the
  caller exactly as before, for the previous release). Only the renamed folder
  re-encrypts its name; descendants keep theirs and get a new path hash.

  When a live folder already sits at `new_folder` (a merge), the source rows are
  folded into the target's: a source row whose new place is taken is retired,
  and its explicit flag moves to the occupant. Rows the previous release made
  without a row simply have nothing to rename here; `ensure/4` fills the new
  paths.
  """
  @spec rename(map(), Ecto.UUID.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def rename(_user, _vault_id, same, same), do: :ok

  def rename(_user, _vault_id, old_folder, new_folder)
      when old_folder == "" or new_folder == "",
      do: {:error, :invalid_path}

  def rename(user, vault_id, old_folder, new_folder) do
    with :ok <- check_move(user, vault_id, old_folder, new_folder),
         do: do_rename(user, vault_id, old_folder, new_folder)
  end

  @doc """
  `:ok` when moving `old_folder` to `new_folder` cannot make a folder its own
  ancestor, else `{:error, :invalid_path}`. Checked by path (the new path is the
  old one or inside it) AND by row: the row that would become the new parent
  must not be one of the moving subtree's rows, which a stale path hash could
  otherwise let through. Runs inside the caller's tenant transaction.
  """
  @spec check_move(map(), Ecto.UUID.t(), String.t(), String.t()) ::
          :ok | {:error, :invalid_path}
  def check_move(user, vault_id, old_folder, new_folder) do
    parent_path = new_folder |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")

    cond do
      old_folder == "" or new_folder == "" ->
        {:error, :invalid_path}

      into_own_subtree?(old_folder, new_folder) ->
        {:error, :invalid_path}

      true ->
        moving = user |> subtree_refs(vault_id, [old_folder]) |> MapSet.new(& &1.id)
        parents = ids_at(user, vault_id, [parent_path])
        if Enum.any?(parents, &MapSet.member?(moving, &1)), do: {:error, :invalid_path}, else: :ok
    end
  end

  @doc """
  True when `new_folder` is `old_folder` or inside it: a move that would make a
  folder its own ancestor. Every folder move checks this before touching a row.
  """
  @spec into_own_subtree?(String.t(), String.t()) :: boolean()
  def into_own_subtree?(old_folder, new_folder),
    do: new_folder == old_folder or String.starts_with?(new_folder, old_folder <> "/")

  defp do_rename(user, vault_id, old_folder, new_folder) do
    with {:ok, dek} <- Crypto.get_dek(user),
         {:ok, fk} <- Crypto.dek_filter_key(user) do
      ctx = %{user_id: user.id, vault_id: vault_id, dek: dek, fk: fk}

      case subtree(user, vault_id, [old_folder]) do
        [] -> :ok
        rows -> move_subtree(ctx, rows, new_folder)
      end
    end
  end

  defp move_subtree(ctx, [root | _] = rows, new_folder) do
    new_segment = new_folder |> String.split("/") |> List.last()
    parent_path = new_folder |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")

    new_parent =
      if parent_path == "", do: nil, else: resolve_all(ctx, %{parent_path => nil})[parent_path]

    new_name_h = name_hmac(ctx.fk, new_segment)

    # Each row's NEW full path, from the decrypted segment names. A name that
    # will not open drops that row and its descendants from the rewrite: the
    # daily FolderTable pass heals them, a corrupt row must not block a rename.
    paths = new_paths(ctx, rows, root.id, new_folder)

    case live_child(ctx.vault_id, new_parent, new_name_h) do
      %{id: occupant} when occupant != root.id ->
        merge_subtree(ctx, rows, paths, root.id, occupant, new_parent)

      _ ->
        {ct, nonce} = encrypt_name(ctx.dek, root.id, new_segment)

        from(f in Folder, where: f.id == ^root.id)
        |> Repo.update_all(
          set: [
            parent_id: new_parent,
            name_ciphertext: ct,
            name_nonce: nonce,
            name_hmac: new_name_h,
            full_path_hmac: path_hmac(ctx.fk, new_folder),
            dek_version: Crypto.row_version_aad_bound(),
            updated_at: now()
          ]
        )

        rest = for r <- rows, r.id != root.id, Map.has_key?(paths, r.id), do: {r.id, paths[r.id]}
        write_path_hmacs(ctx, rest)
        :ok
    end
  end

  # id => new full path, for every row whose chain of names opens.
  defp new_paths(ctx, rows, root_id, new_folder) do
    by_id = Map.new(rows, &{&1.id, &1})

    Enum.reduce(rows, %{}, fn row, acc ->
      with nil <- Map.get(acc, row.id),
           {:ok, path} <- path_of(ctx, row, by_id, root_id, new_folder, acc) do
        Map.put(acc, row.id, path)
      else
        _ -> acc
      end
    end)
  end

  # Rows arrive shallowest first, so a parent's path is already in `acc`.
  defp path_of(_ctx, %{id: id}, _by_id, id, new_folder, _acc), do: {:ok, new_folder}

  defp path_of(ctx, row, _by_id, _root_id, _new_folder, acc) do
    with parent_path when is_binary(parent_path) <- Map.get(acc, row.parent_id),
         {:ok, name} <-
           decrypt_name(ctx.dek, row.id, row.dek_version, row.name_ciphertext, row.name_nonce) do
      {:ok, parent_path <> "/" <> name}
    else
      _ -> :error
    end
  end

  defp write_path_hmacs(_ctx, []), do: :ok

  defp write_path_hmacs(ctx, id_paths) do
    id_paths
    |> Enum.chunk_every(1_000)
    |> Enum.each(fn chunk ->
      ids = Enum.map(chunk, fn {id, _} -> Ecto.UUID.dump!(id) end)
      hmacs = Enum.map(chunk, fn {_, path} -> path_hmac(ctx.fk, path) end)

      from(f in Folder,
        join:
          v in fragment(
            "SELECT * FROM unnest(?::uuid[], ?::bytea[]) AS t(id, fh)",
            ^ids,
            ^hmacs
          ),
        on: f.id == field(v, :id),
        update: [set: [full_path_hmac: field(v, :fh), updated_at: ^now()]]
      )
      |> Repo.update_all([])
    end)

    :ok
  end

  # The target of the rename already has a live row: fold each source row into
  # the row that holds its new place, or move it there.
  defp merge_subtree(ctx, rows, paths, root_id, occupant, new_parent) do
    _ =
      Enum.reduce(rows, %{root_id => occupant}, fn row, placed ->
        case Map.fetch(paths, row.id) do
          :error ->
            placed

          {:ok, _path} when row.id == root_id ->
            retire(row, occupant)
            placed

          {:ok, path} ->
            parent = Map.get(placed, row.parent_id, new_parent)

            case live_child(ctx.vault_id, parent, row.name_hmac) do
              %{id: taken} when taken != row.id ->
                retire(row, taken)
                Map.put(placed, row.id, taken)

              _ ->
                from(f in Folder, where: f.id == ^row.id)
                |> Repo.update_all(
                  set: [
                    parent_id: parent,
                    full_path_hmac: path_hmac(ctx.fk, path),
                    updated_at: now()
                  ]
                )

                Map.put(placed, row.id, row.id)
            end
        end
      end)

    :ok
  end

  # `row` lost its place to `keeper`: its explicit flag moves over, it is retired.
  defp retire(row, keeper) do
    if row.explicit do
      from(f in Folder, where: f.id == ^keeper)
      |> Repo.update_all(set: [explicit: true, updated_at: now()])
    end

    from(f in Folder, where: f.id == ^row.id)
    |> Repo.update_all(set: [deleted_at: now(), updated_at: now()])
  end

  # ---- delete, restore -----------------------------------------------------

  @doc """
  Soft-deletes the live rows at `folders` and every descendant, stamping
  `op_id` (the undo id, nil for a plain delete). Returns how many rows.

  A row that still has a live note or attachment pointing at it, and every
  ancestor of such a row, is left alone: the delete's content legs commit in
  their own transactions, so something written into the folder in between must
  not end up attached to a deleted row. The next delete of the folder finishes it.
  """
  @spec soft_delete(map(), Ecto.UUID.t(), [String.t()], Ecto.UUID.t() | nil) :: non_neg_integer()
  def soft_delete(user, vault_id, folders, op_id) do
    # The vault row first, like a rename (LOCK ORDER in `Engram.Vaults`): the
    # row updates below take their locks in no fixed order, so two writers
    # that skip this lock can deadlock (40P01).
    _ = Engram.Vaults.lock_seq(vault_id)

    case subtree(user, vault_id, folders) do
      [] ->
        0

      rows ->
        ids = Enum.map(rows, & &1.id)
        keep = with_ancestors(live_content_folders(ids), Map.new(rows, &{&1.id, &1.parent_id}))
        doomed = Enum.reject(ids, &MapSet.member?(keep, &1))

        {n, _} =
          from(f in Folder, where: f.id in ^doomed and is_nil(f.deleted_at))
          |> Repo.update_all(
            set: [deleted_at: now(), delete_op_id: op_id, explicit: false, updated_at: now()]
          )

        n
    end
  end

  # Folder ids (among `ids`) that a live note or attachment points at.
  defp live_content_folders(ids) do
    notes =
      from(n in Engram.Notes.Note,
        where: n.kind == "note" and n.folder_ref_id in ^ids and is_nil(n.deleted_at),
        distinct: true,
        select: n.folder_ref_id
      )

    attachments =
      from(a in Engram.Attachments.Attachment,
        where: a.folder_ref_id in ^ids and is_nil(a.deleted_at),
        distinct: true,
        select: a.folder_ref_id
      )

    MapSet.new(Repo.all(notes) ++ Repo.all(attachments))
  end

  defp with_ancestors(set, parents) do
    Enum.reduce(set, set, fn id, acc -> climb(id, parents, acc, @max_depth) end)
  end

  defp climb(_id, _parents, acc, 0), do: acc

  defp climb(id, parents, acc, budget) do
    case Map.get(parents, id) do
      nil -> acc
      parent -> climb(parent, parents, MapSet.put(acc, parent), budget - 1)
    end
  end

  @doc """
  Brings back every folder row `soft_delete/4` stamped with `op_id`. Returns
  how many came back.

  A row whose place a live sibling has since taken (the unique live-name index
  would refuse it) stays deleted, and the rows below it are RE-PARENTED to that
  live sibling: the undo merges into what exists, as a rename onto an existing
  folder does. Reviving them under the dead row instead would leave live folders
  that no walk from a live parent reaches, so a later delete, rename or move
  of the folder would miss their content. Rows arrive shallowest first, so a
  parent's outcome is known when its children are placed. A top row of the op
  whose own parent is no longer live stays deleted, with its subtree.
  """
  @spec restore_op(Ecto.UUID.t(), Ecto.UUID.t()) :: non_neg_integer()
  def restore_op(vault_id, op_id) do
    _ = Engram.Vaults.lock_seq(vault_id)

    rows =
      from(f in Folder,
        where: f.vault_id == ^vault_id and f.delete_op_id == ^op_id and not is_nil(f.deleted_at),
        select: %{id: f.id, parent_id: f.parent_id, name_hmac: f.name_hmac}
      )
      |> Repo.all()

    by_id = Map.new(rows, &{&1.id, &1})

    {revive, _placed} =
      rows
      |> Enum.sort_by(&depth(&1, by_id, @max_depth))
      |> Enum.reduce({[], %{}}, fn row, {revive, placed} ->
        case place_restored(vault_id, row, by_id, placed) do
          :skip -> {revive, placed}
          {:merge, into} -> {revive, Map.put(placed, row.id, into)}
          {:revive, parent} -> {[{row.id, parent} | revive], Map.put(placed, row.id, row.id)}
        end
      end)

    write_revived(revive)
  end

  defp depth(_row, _by_id, 0), do: 0

  defp depth(row, by_id, budget) do
    case Map.get(by_id, row.parent_id) do
      nil -> 0
      parent -> 1 + depth(parent, by_id, budget - 1)
    end
  end

  # Where a deleted row goes: `:skip` (its parent did not come back),
  # `{:merge, live_id}` (a live row holds its place) or `{:revive, parent_id}`.
  defp place_restored(vault_id, row, by_id, placed) do
    parent =
      cond do
        is_nil(row.parent_id) -> {:ok, nil}
        Map.has_key?(by_id, row.parent_id) -> Map.fetch(placed, row.parent_id)
        live?(row.parent_id) -> {:ok, row.parent_id}
        true -> :error
      end

    case parent do
      {:ok, parent_id} ->
        case live_child(vault_id, parent_id, row.name_hmac) do
          nil -> {:revive, parent_id}
          %{id: id} -> {:merge, id}
        end

      _ ->
        :skip
    end
  end

  defp live?(id), do: Repo.exists?(from(f in Folder, where: f.id == ^id and is_nil(f.deleted_at)))

  defp write_revived([]), do: 0

  defp write_revived(revive) do
    {ids, parents} = Enum.unzip(revive)

    {n, _} =
      from(f in Folder,
        join:
          v in fragment(
            "SELECT * FROM unnest(?::uuid[], ?::uuid[]) AS t(id, parent_id)",
            type(^ids, {:array, Ecto.UUID}),
            type(^parents, {:array, Ecto.UUID})
          ),
        on: f.id == field(v, :id),
        update: [
          set: [
            deleted_at: nil,
            delete_op_id: nil,
            parent_id: field(v, :parent_id),
            updated_at: ^now()
          ]
        ]
      )
      |> Repo.update_all([])

    n
  end

  @doc "A deleted folder marker no longer makes its folder explicit; the row stays for its content."
  @spec unmark_explicit(map(), Ecto.UUID.t(), String.t()) :: :ok
  def unmark_explicit(user, vault_id, folder) do
    with {:ok, fk} <- Crypto.dek_filter_key(user) do
      hmac = path_hmac(fk, folder)

      from(f in Folder,
        where:
          f.vault_id == ^vault_id and f.full_path_hmac == ^hmac and is_nil(f.deleted_at) and
            f.explicit
      )
      |> Repo.update_all(set: [explicit: false, updated_at: now()])
    end

    :ok
  end

  defp mint_id, do: UUIDv7.generate()
  defp now, do: DateTime.utc_now()
end
