defmodule Engram.Attachments.Location do
  @moduledoc """
  Where an attachment is: `Engram.Notes.Location`'s rules for attachment rows
  (O(1) folder rename plan, S6 step 6 read switch, Engram#2523). Every
  attachment by-path lookup and every attachment path a reader serves goes
  through here.

  An attachment row stores its path, its folder row (`folder_ref_id`,
  trusted while `folder_ref_stamp == path_nonce`) and its name
  (`Engram.Notes.Name`, trusted while `name_stamp == stamp(path_nonce)`).
  The `attachments_set_name_key` trigger keeps `name_key` set exactly while
  both are current. Writers still cascade attachments on a folder rename in
  this release, so the stored path is the truth for every row EXCEPT a
  current one (`derivable?/1`) under a folder moved without a cascade
  (`folders.notes_cascaded = false`): that one is shown, and found, where
  its folder row puts it, so a later release can stop the attachment
  cascade and this release (its rollback target) still reads it right.

    * **lookup** (`at/4`, `at_any/4`): in a vault holding such a folder
      (`named?/2`, one probe), `(path_key AND here) OR id = <name match>`,
      `Engram.Folders.WalkSql.attachment_name_match/0`; otherwise the
      stored path key alone, the statement the previous release sent.
    * **output** (`shown_paths/3`): `%{id => path}` for the rows shown under
      such a folder, one chain read; every other row keeps its stored path.
      Tombstones are shown at their stored path.

  Unlike a note, a stale attachment (name or reference not current) keeps
  answering at its stored path under a moved folder: it is not derivable,
  so it is shown there too, and the lookup and the listings agree on it.

  Off (`Engram.Notes.Location.on?/0`: the `note_name` ledger, which names
  attachments too, and the `name_reads` kill switch), every function here
  answers what the stored path did.
  """

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.Folders.{Rows, WalkSql}
  alias Engram.Notes.Location, as: NoteLocation
  alias Engram.Notes.Name

  require WalkSql

  @doc """
  This build's attachment-reader level (S6 step 6): 1 reads, writes next
  to and serves (the moved-folder feed's attachment leg) attachments left
  under a folder moved without a cascade. the next release's write stop
  leaves them only while every node answers at least its level; an older
  build has no such function and counts as behind.
  """
  @spec s6_reads() :: 1
  def s6_reads, do: 1

  @doc "The columns `shown_paths/3` reads from a row, beside `id`."
  @spec fields() :: [
          :vault_id
          | :deleted_at
          | :path_nonce
          | :folder_ref_id
          | :folder_ref_stamp
          | :name_ciphertext
          | :name_nonce
          | :name_stamp,
          ...
        ]
  def fields,
    do: [
      :vault_id,
      :deleted_at,
      :path_nonce,
      :folder_ref_id,
      :folder_ref_stamp,
      :name_ciphertext,
      :name_nonce,
      :name_stamp
    ]

  @doc "Whether a lookup in `vault_id` sends the name arms (`Engram.Notes.Location.named?/2`)."
  @spec named?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  defdelegate named?(user_id, vault_id), to: NoteLocation

  @doc """
  The filter for the live attachment at `path` (sanitized) in `vault_id`,
  under the user's `filter_key`. Not `named?`: the stored path key alone.
  """
  @spec at(binary(), Ecto.UUID.t(), String.t(), boolean()) :: Ecto.Query.dynamic_expr()
  def at(filter_key, vault_id, path, named?) do
    hmac = Crypto.hmac_field(filter_key, path)
    key = dynamic([a], a.path_hmac == ^hmac)

    case named? && name_match(filter_key, vault_id, path, hmac) do
      match when match in [nil, false] -> key
      match -> dynamic([a], (^key and ^here()) or a.id == ^match)
    end
  end

  # The id of the live attachment `path`'s folder row and name name, as an
  # InitPlan (`WalkSql.attachment_name_match/0`); nil for a root path, which
  # only its stored key names.
  defp name_match(filter_key, vault_id, path, hmac) do
    case path |> String.split("/") |> Enum.split(-1) do
      {[], _root} ->
        nil

      {folders, [name]} ->
        segs = Enum.map(folders, &Rows.name_hmac(filter_key, &1))

        dynamic(
          fragment(
            WalkSql.attachment_name_match(),
            type(^vault_id, Ecto.UUID),
            type(^vault_id, Ecto.UUID),
            type(^vault_id, Ecto.UUID),
            type(^segs, {:array, :binary}),
            type(^vault_id, Ecto.UUID),
            type(^segs, {:array, :binary}),
            type(^Name.ci_hmac(filter_key, name), :binary),
            ^length(segs),
            type(^Name.hmac(filter_key, name), :binary),
            type(^vault_id, Ecto.UUID),
            type(^hmac, :binary)
          )
        )
    end
  end

  @doc """
  The rows a write at `paths` must repoint first, in a vault where
  `named?/2` holds: `[{row, stored, shown}]` for each live attachment whose
  stored path differs from where it is shown and that either holds one of
  `paths` by its stored key (a write there needs that unique slot) or is
  shown at one of them by name. Holders first. A batch costs a fixed
  number of statements whatever its size: the stored-key read, the folder
  walk and name probes (`Engram.Notes.Location.named_ids_at/4`), the rows,
  and their chains; plus one batch path decrypt. Run it in `user`'s tenant
  transaction.
  """
  @spec stale_rows(map(), Ecto.UUID.t(), binary(), [String.t()]) :: [
          {map(), String.t(), String.t()}
        ]
  def stale_rows(_user, _vault_id, _filter_key, []), do: []

  def stale_rows(user, vault_id, filter_key, paths) do
    hmacs = Enum.map(paths, &Crypto.hmac_field(filter_key, &1))
    named = NoteLocation.named_ids_at(user, vault_id, paths, :attachments)

    rows =
      Engram.Repo.all(
        from(a in Engram.Attachments.scoped_live(user, vault_id),
          where: a.path_hmac in ^hmacs or a.id in ^Map.values(named),
          select: struct(a, ^row_fields())
        )
      )

    stale_of(user, rows, MapSet.new(hmacs))
  end

  @doc "The columns a repoint reads from a row (`stale_rows/4`, `stale_of/3`)."
  @spec row_fields() :: [
          :id
          | :path_ciphertext
          | :path_hmac
          | :dek_version
          | :vault_id
          | :deleted_at
          | :path_nonce
          | :folder_ref_id
          | :folder_ref_stamp
          | :name_ciphertext
          | :name_nonce
          | :name_stamp,
          ...
        ]
  def row_fields, do: [:id, :path_ciphertext, :path_hmac, :dek_version | fields()]

  @doc """
  `rows` (with `row_fields/0`) whose stored path differs from where they are
  shown, as `[{row, stored, shown}]`, the rows holding a key in `holders`
  first. One chain read, one batch decrypt.
  """
  @spec stale_of(map(), [map()], MapSet.t()) :: [{map(), String.t(), String.t()}]
  def stale_of(_user, [], _holders), do: []

  def stale_of(user, rows, holders) do
    shown = shown_paths(user, rows)

    for row <- Enum.sort_by(rows, &(not MapSet.member?(holders, &1.path_hmac))),
        moved = shown[row.id],
        moved != nil,
        {:ok, %{path: stored}} <- [Crypto.maybe_decrypt_attachment_fields(row, user)],
        moved != stored,
        do: {row, stored, moved}
  end

  @doc "`at/4` for any of `paths` (a batch op's few hundred at most: one walk each when named)."
  @spec at_any(binary(), Ecto.UUID.t(), [String.t()], boolean()) :: Ecto.Query.dynamic_expr()
  def at_any(filter_key, _vault_id, paths, false) do
    hmacs = Enum.map(paths, &Crypto.hmac_field(filter_key, &1))
    dynamic([a], a.path_hmac in ^hmacs)
  end

  def at_any(filter_key, vault_id, paths, true) do
    paths
    |> Enum.uniq()
    |> Enum.map(&at(filter_key, vault_id, &1, true))
    |> Enum.reduce(dynamic(false), &dynamic(^&2 or ^&1))
  end

  # A row found by its stored path key is at that path unless it is current
  # and its own chain moved (then it is shown, and found, under the moved
  # folder). O(depth) primary-key probes, for the matched row(s) only.
  defp here do
    dynamic(
      [a],
      is_nil(a.name_key) or not fragment(WalkSql.moved_chain(), a.folder_ref_id)
    )
  end

  @doc "Whether `row`'s location comes from its folder row and name (see the moduledoc)."
  @spec derivable?(map()) :: boolean()
  def derivable?(row),
    do: NoteLocation.derivable?(row) and row.folder_ref_stamp == row.path_nonce

  @doc """
  `%{id => path}` for the `rows` (attachments of `user`, any vault, with
  `fields/0`) shown under a folder moved without a cascade: their folder
  row's path plus their name. Rows not in the map keep their stored path.
  Nothing is read while names are off or no row is derivable; else one
  chain statement per vault (`Rows.chain_rows/3`, `moved_only`, one index
  probe unless the vault holds such a folder), in `user`'s tenant (the
  caller's transaction when it is in one), and one batch name decrypt for
  the rows it places.
  """
  @spec shown_paths(map(), [map()], boolean() | :probe) :: %{Ecto.UUID.t() => String.t()}
  def shown_paths(user, rows, on? \\ :probe) do
    with true <- if(on? == :probe, do: NoteLocation.on?(), else: on?),
         [_ | _] = named <- Enum.filter(rows, &derivable?/1),
         {:ok, dek} <- Crypto.get_dek(user) do
      chains =
        Engram.Repo.with_tenant!(user.id, fn ->
          named
          |> Enum.group_by(& &1.vault_id, & &1.folder_ref_id)
          |> Enum.flat_map(fn {vault_id, ids} ->
            Rows.chain_rows(vault_id, Enum.uniq(ids), moved_only: true)
          end)
        end)

      if chains == [],
        do: %{},
        else: NoteLocation.derive(:attachments, dek, named, &Rows.moved_paths(dek, chains, &1))
    else
      _ -> %{}
    end
  end

  @doc """
  What a whole-vault listing (`/sync/manifest`) serves for the attachments
  shown under a folder moved without a cascade: `{%{id => path}, %{id =>
  seq}}`, the seq being the highest such folder's on the row's chain, so a
  client comparing seqs sees the row changed when the move did. `moved?`
  is the vault's moved bit when the caller knows it (the notes read's),
  else `:probe` sends `named?/2`. Both maps empty, reading nothing past the
  probe, in any vault without such a folder; else one O(attachments) read
  of small columns (no content), one chain read, and one name decrypt per
  placed row.
  """
  @spec listing(map(), Ecto.UUID.t(), boolean() | :probe) ::
          {%{Ecto.UUID.t() => String.t()}, %{Ecto.UUID.t() => integer()}}
  def listing(user, vault_id, moved? \\ :probe) do
    moved? =
      if moved? == :probe, do: named?(user.id, vault_id), else: moved? and NoteLocation.on?()

    with true <- moved?,
         {:ok, dek} <- Crypto.get_dek(user) do
      {rows, chains} =
        Engram.Repo.with_tenant!(user.id, fn ->
          rows =
            Engram.Repo.all(
              from(a in Engram.Attachments.scoped_live(user, vault_id),
                select: struct(a, ^[:id | fields()])
              )
            )
            |> Enum.filter(&derivable?/1)

          refs = rows |> Enum.map(& &1.folder_ref_id) |> Enum.uniq()
          {rows, Rows.chain_rows(vault_id, refs, moved_only: true)}
        end)

      by_folder = Rows.moved_seqs(chains, rows |> Enum.map(& &1.folder_ref_id) |> Enum.uniq())
      paths = NoteLocation.derive(:attachments, dek, rows, &Rows.moved_paths(dek, chains, &1))

      {paths,
       for(
         r <- rows,
         Map.has_key?(paths, r.id),
         seq = by_folder[r.folder_ref_id],
         into: %{},
         do: {r.id, seq}
       )}
    else
      _ -> {%{}, %{}}
    end
  end

  @doc """
  `metas` (maps with `:id` and `:path`, decrypted from `rows`) with each
  path replaced by `shown_paths/3`'s.
  """
  @spec put_paths(map(), [map()], [map()]) :: [map()]
  def put_paths(_user, _rows, []), do: []

  def put_paths(user, rows, metas) do
    case shown_paths(user, rows) do
      none when none == %{} -> metas
      shown -> Enum.map(metas, &%{&1 | path: Map.get(shown, &1.id, &1.path)})
    end
  end
end
