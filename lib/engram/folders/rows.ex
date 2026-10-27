defmodule Engram.Folders.Rows do
  @moduledoc """
  The one place that reads and writes `folders` rows (migration 20261027000000):
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
      {:ok, resolve(ctx, folder, Keyword.get(opts, :explicit))}
    end
  end

  @doc """
  `ensure/4` for many folders: `{:ok, %{folder => id}}`. Sorted, so two
  concurrent batches create shared ancestors in the same order and cannot
  deadlock on each other's unique-index entries.
  """
  @spec ensure_all(map(), Ecto.UUID.t(), [String.t()]) ::
          {:ok, %{String.t() => Ecto.UUID.t() | nil}} | {:error, term()}
  def ensure_all(user, vault_id, folders) do
    folders
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn folder, {:ok, acc} ->
      case ensure(user, vault_id, folder) do
        {:ok, id} -> {:cont, {:ok, Map.put(acc, folder, id)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp resolve(ctx, folder, explicit) do
    prefixes = prefixes(folder)
    known = live_ids_by_path_hmac(ctx.vault_id, Enum.map(prefixes, &path_hmac(ctx.fk, &1)))

    # Start below the deepest ancestor that already has a row.
    {parent, missing} =
      prefixes
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value({nil, prefixes}, fn {prefix, i} ->
        case Map.get(known, path_hmac(ctx.fk, prefix)) do
          nil -> nil
          id -> {id, Enum.drop(prefixes, i + 1)}
        end
      end)

    case missing do
      [] ->
        if explicit, do: mark_explicit(ctx, parent)
        parent

      _ ->
        last = List.last(missing)

        Enum.reduce(missing, parent, fn path, parent_id ->
          marker = if path == last, do: explicit
          step(ctx, parent_id, path, marker)
        end)
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
  defp step(ctx, parent_id, path, explicit, attempts \\ 3) do
    segment = path |> String.split("/") |> List.last()
    name_h = name_hmac(ctx.fk, segment)
    full_h = path_hmac(ctx.fk, path)

    case live_child(ctx.vault_id, parent_id, name_h) do
      %{id: id} = row ->
        repair(row, full_h, explicit)
        id

      nil ->
        id = explicit || mint_id()

        case insert(ctx, id, parent_id, segment, name_h, full_h, explicit != nil) do
          1 ->
            id

          # Lost a race (or `explicit` names a row that exists elsewhere): read
          # the winner, or revive the marker's own row, then retry.
          0 when attempts > 0 ->
            revive_or_retry(ctx, explicit, parent_id, segment, name_h, full_h)
            step(ctx, parent_id, path, explicit, attempts - 1)

          0 ->
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

  defp mark_explicit(_ctx, id) do
    from(f in Folder, where: f.id == ^id and not f.explicit)
    |> Repo.update_all(set: [explicit: true, updated_at: now()])
  end

  defp insert(ctx, id, parent_id, segment, name_h, full_h, explicit?) do
    {ct, nonce} = encrypt_name(ctx.dek, id, segment)

    {n, _} =
      Repo.insert_all(
        Folder,
        [
          %{
            id: id,
            user_id: ctx.user_id,
            vault_id: ctx.vault_id,
            parent_id: parent_id,
            name_ciphertext: ct,
            name_nonce: nonce,
            name_hmac: name_h,
            full_path_hmac: full_h,
            dek_version: Crypto.row_version_aad_bound(),
            explicit: explicit?,
            inserted_at: now(),
            updated_at: now()
          }
        ],
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

  defp mint_id, do: UUIDv7.generate()
  defp now, do: DateTime.utc_now()
end
