defmodule Engram.Folders.Rows do
  @moduledoc """
  The one place that reads and writes `folders` rows (migration 20261029000000):
  key derivation, name encryption, find-or-create of a path, subtree lookups,
  rename, soft delete and restore.

  Every function that touches the table MUST run inside the caller's
  `Repo.with_tenant/2` (the table has FORCE row security). Writers call
  `ensure/4` (or `ensure_all/3`) inside the transaction that writes the note or
  attachment and set its `folder_ref_id` from the result in the same write, so
  the composite foreign key finds the row. Nothing derives it in the database
  (the `notes_set_folder_ref` trigger was dropped in R9 release D).

  Names are one path SEGMENT, encrypted under the account's per-user DEK with
  AAD `Crypto.aad_for_row(:folders, :name, id)` (the key scheme of
  `notes.folder_ciphertext`). `name_hmac` lives in its own domain so a segment
  hash never equals a `path_hmac`. `full_path_hmac` is the HMAC of the whole
  path and equals a marker's `folder_hmac` (and a note's, while note writes
  still set it); it is rewritten for a renamed subtree.

  The stored paths (`notes.path_*` / `folder_*`, attachment `path_*`) stay
  authoritative and are still written everywhere; a folder row is a second,
  derived key (see `Engram.DataMigrations.FolderTable`, which heals whatever
  the previous release wrote).
  """

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Folders.Folder
  alias Engram.Logger.Metadata
  alias Engram.Repo
  alias Engram.Search.NameTerms

  require Logger

  # ---- keys and names (pure) ----------------------------------------------

  @doc "HMAC of one path segment, in the folder-name domain."
  @spec name_hmac(binary(), String.t()) :: binary()
  defdelegate name_hmac(filter_key, segment), to: Folder

  @doc "HMAC of a whole folder path: a folder row's `full_path_hmac`, a marker's `folder_hmac`."
  @spec path_hmac(binary(), String.t()) :: binary()
  def path_hmac(filter_key, path), do: Crypto.hmac_field(filter_key, path)

  @doc """
  Decrypts one row-bound envelope, `table.column` of the row `id` (raw 16
  bytes, as Postgrex returns it) at `dek_version`, under `dek`:
  `{:ok, plaintext}`, or `:error` for a missing or undecryptable one.
  """
  @spec decrypt_field(binary(), atom(), atom(), binary(), integer(), binary() | nil, binary()) ::
          {:ok, binary()} | :error
  def decrypt_field(dek, table, column, id, dek_version, ct, nonce) do
    aad =
      if Crypto.aad_bound?(dek_version),
        do: Crypto.aad_for_row(table, column, Ecto.UUID.load!(id)),
        else: <<>>

    case ct && Envelope.decrypt(ct, nonce, dek, aad) do
      {:ok, plaintext} -> {:ok, plaintext}
      _ -> :error
    end
  end

  @doc "Encrypts a segment for the folder row `id` (a canonical UUID string)."
  @spec encrypt_name(<<_::256>>, binary(), binary()) :: {binary(), binary()}
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

  @doc "The parent path of `path` (\"\" for a folder at the root)."
  @spec parent_path(String.t()) :: String.t()
  def parent_path(path), do: path |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")

  @doc "Every ancestor path of `path`, shallowest first, `path` itself last."
  @spec prefixes(String.t()) :: [String.t()]
  def prefixes(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.scan(fn seg, acc -> acc <> "/" <> seg end)
  end

  # ---- attachment references ----------------------------------------------

  @doc """
  The columns that point an attachment at its folder row `ref` (nil at the
  root), stamped with the `path_nonce` of the path the folder was taken from.
  Every writer of `attachments.folder_ref_id` goes through here: a reference is
  trusted only while its stamp equals the row's `path_nonce`
  (`attachment_ref_current/0`), so a writer that rewrites the path without this
  (the previous release, a raw update) leaves a mismatch that readers check by
  path and `Engram.Bookkeeping.Drain` heals through `attachments_folder_ref_stale`.
  """
  @spec attachment_ref(Ecto.UUID.t() | nil, binary()) :: keyword()
  def attachment_ref(ref, path_nonce) when is_binary(path_nonce),
    do: [folder_ref_id: ref, folder_ref_stamp: path_nonce]

  @doc """
  The stamp a path re-encryption that keeps the folder (a DEK rotation) carries
  forward: `[folder_ref_stamp: new_nonce]` if the reference was current under
  `old_nonce`, else nothing (a stale reference stays stale for the drain).
  """
  @spec carry_attachment_ref(binary() | nil, binary(), binary()) :: keyword()
  def carry_attachment_ref(stamp, old_nonce, new_nonce)
  def carry_attachment_ref(stamp, stamp, new_nonce), do: [folder_ref_stamp: new_nonce]
  def carry_attachment_ref(_stamp, _old_nonce, _new_nonce), do: []

  @doc """
  The stamp `FolderTable` leaves on an attachment whose path did not decrypt
  under `path_nonce`: the nonce behind a 0 byte. It is excluded from
  `attachments_folder_ref_stale`, so the drain does not re-run the user
  forever. A folder reader takes such a row only by the reference it still
  carries (`attachment_ref_placed/0`) and counts it unreadable (a refusal, an
  orphan log); one with no reference is in no folder. A writer's fresh nonce
  ends it.
  """
  @spec unreadable_attachment_stamp(binary()) :: nonempty_binary()
  def unreadable_attachment_stamp(path_nonce), do: <<0>> <> path_nonce

  @doc "`a.folder_ref_stamp = a.path_nonce` on the attachment bound as `:a`."
  @spec attachment_ref_current() :: Ecto.Query.dynamic_expr()
  def attachment_ref_current,
    do: dynamic([a: a], a.folder_ref_stamp == a.path_nonce)

  @doc """
  The rows whose reference places them in a folder, on the attachment bound
  as `:a`: a current reference, or one `FolderTable` stamped unreadable
  (`unreadable_attachment_stamp/1`), which the caller counts unreadable.
  """
  @spec attachment_ref_placed() :: Ecto.Query.dynamic_expr()
  def attachment_ref_placed,
    do:
      dynamic(
        [a: a],
        ^attachment_ref_current() or
          fragment("? = ('\\x00'::bytea || ?)", a.folder_ref_stamp, a.path_nonce)
      )

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

  def ensure(user, vault_id, folder, opts) do
    case normalize(folder) do
      "" ->
        {:ok, nil}

      path ->
        with {:ok, ids} <- ensure_set(user, vault_id, %{path => Keyword.get(opts, :explicit)}),
             do: {:ok, ids[path]}
    end
  end

  # "A//B", "/A/" and "A/B/" name the same folders `prefixes/1` walks (it drops
  # empty segments): key every result by this one form.
  defp normalize(folder), do: folder |> String.split("/", trim: true) |> Enum.join("/")

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
    with {:ok, ids} <- ensure_set(user, vault_id, Map.new(folders, &{normalize(&1), nil})) do
      {:ok, Map.new(folders, &{&1, Map.get(ids, normalize(&1))})}
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
      |> Map.new(fn {folder, marker_id} -> {normalize(folder), marker_id} end)

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
        segment = segment(path)
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

    put_names(
      ctx,
      for({path, _, _, id, _} <- rows, MapSet.member?(written, id), do: {id, segment(path)}),
      :new
    )

    Enum.reduce(rows, ids, fn {path, parent, marker, id, _row}, ids ->
      if MapSet.member?(written, id),
        do: Map.put(ids, path, id),
        else: Map.put(ids, path, step(ctx, parent, path, marker, 3, false))
    end)
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
    segment = segment(path)
    name_h = name_hmac(ctx.fk, segment)
    full_h = path_hmac(ctx.fk, path)
    id = explicit || mint_id()

    case if(insert?,
           do: insert(ctx, id, parent_id, segment, full_h, explicit != nil),
           else: 0
         ) do
      1 ->
        put_names(ctx, [{id, segment}], :new)
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
      # Its terms are written by `put_names/3` in the same transaction.
      name_terms_stamp: NameTerms.stamp(name_hmac(ctx.fk, segment)),
      full_path_hmac: full_h,
      dek_version: Crypto.row_version_aad_bound(),
      explicit: explicit?,
      inserted_at: now,
      updated_at: now
    }
    |> Map.merge(Map.new(Folder.name_keys(ctx.fk, segment, nonce)))
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
      set:
        [
          parent_id: parent_id,
          name_ciphertext: ct,
          name_nonce: nonce,
          full_path_hmac: full_h,
          dek_version: Crypto.row_version_aad_bound(),
          explicit: true,
          deleted_at: nil,
          delete_op_id: nil,
          updated_at: now()
        ] ++ Folder.name_keys(ctx.fk, segment, nonce)
    )

    put_names(ctx, [{id, segment}])
  end

  # The folder name writers' `name_terms` hook (create, revive, rename): only
  # the rows whose name was just written, never their descendants.
  defp put_names(ctx, refs),
    do:
      NameTerms.put_folders(
        ctx.user_id,
        ctx.fk,
        for({id, seg} <- refs, do: {id, ctx.vault_id, seg})
      )

  # Rows just inserted by `build_row/6`, which set their stamp: the terms only.
  defp put_names(ctx, refs, :new),
    do:
      NameTerms.put_folders(
        ctx.user_id,
        ctx.fk,
        for({id, seg} <- refs, do: {id, ctx.vault_id, seg}),
        :new
      )

  defp segment(path), do: path |> String.split("/") |> List.last()

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

  # A cycle in `parent_id` (never written by this module, but a bad row from any
  # path must not pin a connection in an endless recursion) is cut at this depth.
  @max_depth 512

  @doc """
  `%{path => id}` for the live rows at `paths`, read only (`ensure_all/3`
  without the create): a path with no live row maps to nil, as does the root.
  """
  @spec ids_by_path(map(), Ecto.UUID.t(), [String.t()]) :: %{String.t() => Ecto.UUID.t() | nil}
  def ids_by_path(user, vault_id, paths) do
    case Crypto.dek_filter_key(user) do
      {:ok, fk} ->
        hmacs = for p <- paths, p != "", into: %{}, do: {p, path_hmac(fk, p)}
        known = live_ids_by_path_hmac(vault_id, Map.values(hmacs))
        Map.new(paths, &{&1, Map.get(known, hmacs[&1])})

      {:error, _} ->
        Map.new(paths, &{&1, nil})
    end
  end

  @doc """
  The full path of the live folder row `id`, from its chain of parents up to
  the root: one recursive read, O(depth), and one name decrypt per level.
  `{:error, :not_found}` when the row, or any ancestor, is missing or dead, or
  a name will not open.
  """
  @spec path_by_id(map(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, String.t()} | {:error, :not_found}
  def path_by_id(user, vault_id, id) do
    live = fn query -> where(query, [f], f.vault_id == ^vault_id and is_nil(f.deleted_at)) end

    leaf =
      from(f in Folder,
        where: f.id == ^id,
        select: %{id: f.id, parent_id: f.parent_id, depth: fragment("0")}
      )
      |> live.()

    up =
      from(f in Folder,
        join: t in "folder_up",
        on: f.id == t.parent_id,
        where: t.depth < @max_depth,
        select: %{id: f.id, parent_id: f.parent_id, depth: fragment("? + 1", t.depth)}
      )
      |> live.()

    chain =
      from(f in Folder, join: t in "folder_up", on: f.id == t.id, order_by: [desc: t.depth])
      |> recursive_ctes(true)
      |> with_cte("folder_up", as: ^union_all(leaf, ^up))
      |> Repo.all()

    with {:ok, dek} <- Crypto.get_dek(user),
         [%{parent_id: nil} | _] <- chain,
         {:ok, names} <- decrypt_chain(dek, chain) do
      {:ok, Enum.join(names, "/")}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Every live folder row of `vault_id`, names still encrypted: what
  `decrypt_tree/2` takes. O(folders). Runs inside the caller's tenant
  transaction; decrypt outside it.
  """
  @spec live_rows(Ecto.UUID.t()) :: [map()]
  def live_rows(vault_id) do
    from(f in Folder,
      where: f.vault_id == ^vault_id and is_nil(f.deleted_at),
      select: %{
        id: f.id,
        parent_id: f.parent_id,
        dek_version: f.dek_version,
        ct: f.name_ciphertext,
        nonce: f.name_nonce
      }
    )
    |> Repo.all()
  end

  @doc """
  `live_rows/1` with names decrypted and each row's full `path`, as
  `[%{id, parent_id, name, path}]`, parents before children. A row whose name
  or ancestor chain does not open (a dead or missing parent, a cycle) is
  left out: it has no place to show, and the FolderTable heal repairs it.
  """
  @spec decrypt_tree(binary(), [map()]) :: [map()]
  def decrypt_tree(dek, rows) do
    named =
      for {r, {:ok, name}} <- Enum.zip(rows, decrypt_names(dek, rows)),
          into: %{},
          do: {r.id, %{id: r.id, parent_id: r.parent_id, name: name}}

    # Depth-first from the root, so a row is reached only through live, named
    # parents (preorder: parents first). A cycle never links to the root, so
    # it is never reached. Recursion is as deep as the tree.
    named |> Map.values() |> Enum.group_by(& &1.parent_id) |> place(nil, "")
  end

  # `live_rows/1`'s names in one native call (`Envelope.decrypt_many/3`, the
  # batch the manifest's paths use), `{:ok, name} | :error` per row. The batch
  # is all-or-nothing, so a row that will not open sends the page through the
  # per-row decrypt, which skips just that row.
  defp decrypt_names(dek, rows) do
    bound = Crypto.row_version_aad_bound()

    fields =
      Enum.map(rows, fn r ->
        {Ecto.UUID.dump!(r.id), is_integer(r.dek_version) and r.dek_version >= bound, r.ct,
         r.nonce}
      end)

    case Envelope.decrypt_many(dek, Crypto.aad_prefix(:folders, :name), fields) do
      {:ok, names} -> Enum.map(names, &{:ok, &1})
      :error -> Enum.map(rows, &decrypt_name(dek, &1.id, &1.dek_version, &1.ct, &1.nonce))
    end
  end

  defp place(children, parent, prefix) do
    children
    |> Map.get(parent, [])
    |> Enum.flat_map(fn kid ->
      row = Map.put(kid, :path, Path.join(prefix, kid.name))
      [row | place(children, kid.id, row.path)]
    end)
  end

  # Root first; each row must be the parent of the next, so a missing or dead
  # ancestor (the walk stops at it) leaves a chain that does not reach root.
  defp decrypt_chain(dek, chain) do
    chain
    |> Enum.reduce_while({:ok, [], nil}, fn row, {:ok, acc, parent} ->
      with true <- row.parent_id == parent,
           {:ok, name} <-
             decrypt_name(dek, row.id, row.dek_version, row.name_ciphertext, row.name_nonce) do
        {:cont, {:ok, [name | acc], row.id}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, names, _} -> {:ok, Enum.reverse(names)}
      :error -> :error
    end
  end

  # The recursive walk from `roots` (a query of `%{id, depth}`) down the live
  # folders of `vault_id`: the CTE pieces, for `subtree_query/2` and
  # `descendant_ids/3` to select from.
  defp walk_down(vault_id, roots) do
    walk =
      from(f in Folder,
        join: t in "folder_subtree",
        on: f.parent_id == t.id,
        where: f.vault_id == ^vault_id and is_nil(f.deleted_at) and t.depth < @max_depth,
        select: %{id: f.id, depth: fragment("? + 1", t.depth)}
      )

    union_all(roots, ^walk)
  end

  defp subtree_query(_vault_id, []), do: from(f in Folder, where: false)

  defp subtree_query(vault_id, root_hmacs) do
    roots =
      from(f in Folder,
        where:
          f.vault_id == ^vault_id and f.full_path_hmac in ^root_hmacs and is_nil(f.deleted_at),
        select: %{id: f.id, depth: fragment("0")}
      )

    from(f in Folder,
      join: t in "folder_subtree",
      on: f.id == t.id,
      order_by: [asc: t.depth, asc: f.id]
    )
    |> recursive_ctes(true)
    |> with_cte("folder_subtree", as: ^walk_down(vault_id, roots))
  end

  @doc """
  The ids of the live folder `root_id` and every live descendant, each once,
  shallowest first, at most `limit` of them (the caller passes its cap plus
  one to learn the subtree is over it). A cycle in `parent_id` is walked to
  the depth cap and its repeats collapsed (a folder is in the subtree once),
  so a cycle is never mistaken for a large subtree. A missing or deleted root
  gives `[]`. Runs inside the caller's tenant transaction. The cap bounds the
  answer, not the walk: Postgres still visits the whole subtree.
  """
  @spec descendant_ids(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) :: [Ecto.UUID.t()]
  def descendant_ids(vault_id, root_id, limit) do
    roots =
      from(f in Folder,
        where: f.vault_id == ^vault_id and f.id == ^root_id and is_nil(f.deleted_at),
        select: %{id: f.id, depth: fragment("0")}
      )

    from(t in "folder_subtree",
      group_by: t.id,
      order_by: [asc: min(t.depth), asc: t.id],
      limit: ^limit,
      select: type(t.id, Ecto.UUID)
    )
    |> recursive_ctes(true)
    |> with_cte("folder_subtree", as: ^walk_down(vault_id, roots))
    |> Repo.all()
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

  The source rows a merge folds away are retired by `retire_later/2`: at
  the end of the enclosing `with_deferred_retires/1` (every REST and MCP
  folder move, through `Folders.atomic/1`), after the notes AND attachments
  have been re-pointed; at once with no such owner. Retiring before the moves
  would make the `folders_release_refs` trigger NULL every moved row's
  reference and the move write it again: two writes per row (#2468 reviews).
  After them it releases only the stragglers.
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
    parent_path = parent_path(new_folder)

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
    new_segment = segment(new_folder)
    parent_path = parent_path(new_folder)

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
          set:
            [
              parent_id: new_parent,
              name_ciphertext: ct,
              name_nonce: nonce,
              full_path_hmac: path_hmac(ctx.fk, new_folder),
              dek_version: Crypto.row_version_aad_bound(),
              updated_at: now()
            ] ++ Folder.name_keys(ctx.fk, new_segment, nonce)
        )

        :ok = put_names(ctx, [{root.id, new_segment}])
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
  # the row that holds its new place, or move it there. The rows that lose
  # their place are retired by `retire_later/2` (see `rename/4`).
  defp merge_subtree(ctx, rows, paths, root_id, occupant, new_parent) do
    {_placed, merged} =
      Enum.reduce(rows, {%{root_id => occupant}, []}, fn row, {placed, merged} ->
        case Map.fetch(paths, row.id) do
          :error ->
            {placed, merged}

          {:ok, _path} when row.id == root_id ->
            {placed, [{row, occupant} | merged]}

          {:ok, path} ->
            parent = Map.get(placed, row.parent_id, new_parent)

            case live_child(ctx.vault_id, parent, row.name_hmac) do
              %{id: taken} when taken != row.id ->
                {Map.put(placed, row.id, taken), [{row, taken} | merged]}

              _ ->
                from(f in Folder, where: f.id == ^row.id)
                |> Repo.update_all(
                  set: [
                    parent_id: parent,
                    full_path_hmac: path_hmac(ctx.fk, path),
                    updated_at: now()
                  ]
                )

                {Map.put(placed, row.id, row.id), merged}
            end
        end
      end)

    retire_later(ctx.user_id, Enum.reverse(merged))
  end

  @retires :engram_folder_retires

  @doc """
  Runs `fun` (returning `{:ok, _}` or `{:error, _}`) as the owner of the
  merge retires `rename/4` queues: on `{:ok, _}` they run last, each in its
  user's tenant block, inside the caller's transaction (a rollback undoes
  them); on an error they are dropped with the rest. Nested calls join the
  outer owner. The `Repo.after_commit/1` pattern, for a step that must stay
  inside the transaction.
  """
  @spec with_deferred_retires((-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def with_deferred_retires(fun) do
    if Process.get(@retires) do
      fun.()
    else
      Process.put(@retires, [])

      try do
        with {:ok, _} = ok <- fun.() do
          @retires
          |> Process.get()
          |> Enum.reverse()
          |> Enum.each(fn {user_id, merged} ->
            Repo.with_tenant!(user_id, fn -> retire_merged(merged) end)
          end)

          ok
        end
      after
        Process.delete(@retires)
      end
    end
  end

  # Queued for the owner, or retired at once (inside the caller's tenant block).
  defp retire_later(_user_id, []), do: :ok

  defp retire_later(user_id, merged) do
    case Process.get(@retires) do
      nil -> retire_merged(merged)
      queue -> Process.put(@retires, [{user_id, merged} | queue])
    end

    :ok
  end

  defp retire_merged(merged), do: Enum.each(merged, fn {row, keeper} -> retire(row, keeper) end)

  # `row` lost its place to `keeper`: its explicit flag moves over, it is retired.
  # The flag is read from the row NOW, in the same statement, not from the
  # struct queued earlier: in a chained merge (one owner, the second merge's
  # source is the first one's keeper) the first retire sets it after the
  # second was queued. The queue is FIFO, so the flag lands at the end.
  defp retire(row, keeper) do
    explicit = from(s in Folder, where: s.id == ^row.id and s.explicit, select: 1)

    from(f in Folder, where: f.id == ^keeper and not f.explicit and exists(explicit))
    |> Repo.update_all(set: [explicit: true, updated_at: now()])

    from(f in Folder, where: f.id == ^row.id)
    |> Repo.update_all(set: [deleted_at: now(), updated_at: now()])

    NameTerms.on_folders_deleted([row.id])
  end

  # ---- delete, restore -----------------------------------------------------

  @doc """
  Soft-deletes the live rows at `folders` and every descendant, stamping
  `op_id` (the undo id, nil for a plain delete). Returns how many rows.

  A row that still has a live note or attachment pointing at it, or a live
  folder marker at its path, and every ancestor of such a row, is left alone:
  the delete's content legs commit in their own transactions, so something
  written into the folder in between must not end up attached to a deleted
  row. The next delete of the folder finishes it. Every writer takes the
  vault row lock this takes first, so what it counts is everything committed.

  A marker counts like content (#2466 review, H2): a marker created after
  the delete's scan would otherwise be left live over a deleted row, a folder
  the tree still shows and no later delete or rename can find. Markers carry
  no `folder_ref_id` (the previous release's folder counts would drop an
  empty marker folder that had one), so they are matched by path hash.
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
        content = live_content_folders(ids)
        marked = live_marker_folders(user, vault_id, rows)
        log_kept_by_marker(user, vault_id, MapSet.size(MapSet.difference(marked, content)))

        keep =
          with_ancestors(MapSet.union(content, marked), Map.new(rows, &{&1.id, &1.parent_id}))

        doomed = Enum.reject(ids, &MapSet.member?(keep, &1))

        {n, _} =
          from(f in Folder, where: f.id in ^doomed and is_nil(f.deleted_at))
          |> Repo.update_all(
            set: [deleted_at: now(), delete_op_id: op_id, explicit: false, updated_at: now()]
          )

        :ok = NameTerms.on_folders_deleted(doomed)
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

  # A marker the delete's own marker leg did not remove (its path did not
  # decrypt, or the membership fence skipped it as moved) keeps its folder:
  # say so, by count only, rather than report a clean delete silently.
  defp log_kept_by_marker(_user, _vault_id, 0), do: :ok

  defp log_kept_by_marker(user, vault_id, count) do
    Logger.warning(
      "folder delete: rows kept for live folder markers",
      Metadata.with_category(:warning, :sync,
        user_id: user.id,
        vault_id: vault_id,
        kept_count: count
      )
    )
  end

  # Folder ids (among `rows`) whose path a live folder marker names.
  defp live_marker_folders(user, vault_id, rows) do
    hmacs = for %{full_path_hmac: h} when is_binary(h) <- rows, do: h
    named = Engram.Notes.live_folder_marker_hmacs(user, vault_id, hmacs)
    for %{id: id, full_path_hmac: h} <- rows, MapSet.member?(named, h), into: MapSet.new(), do: id
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
