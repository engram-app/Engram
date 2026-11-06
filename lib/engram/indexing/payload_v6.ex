defmodule Engram.Indexing.PayloadV6 do
  @moduledoc """
  The v6 note-level Qdrant payload: v5's key set and typed frontmatter scheme
  (`Engram.Indexing.PayloadV5` builds it, this module reuses that) with `f`
  holding the note's folder ROW id (`notes.folder_ref_id`, undashed uuid)
  instead of the HMAC of the folder path. A folder move or rename then changes
  no payload, and a subtree is the folder's descendant ids expanded at query
  time (`Engram.Folders.descendant_ids/3`). A note in the vault root has no
  folder row and no `f`.

  `build_from_rows/3` derives the payload from Postgres rows only: the note
  row plus its `note_attrs` rows (the typed source of truth the indexing pass
  writes from the same extraction), so the rewrite sweep decrypts and parses
  no note body. `from_rows_or_extract/4` falls back to the extracting path for
  a note whose rows are missing or not provably current (`fresh?/1`).

  `fa` is sorted so the two paths agree byte for byte (the stamp
  `payload_hash` hashes the term, and extraction order is not row order).

  NOT wired to any writer yet: release R-a ships the builder and its parity
  test only (`docs/context/payload-v6.md`).
  """

  import Ecto.Query, only: [from: 2, where: 2]

  alias Engram.Indexing.PayloadV5
  alias Engram.Notes.FlatFields
  alias Engram.Notes.FrontmatterKeys
  alias Engram.Notes.Note
  alias Engram.Notes.NoteIndexState
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.Vector.FilterId
  alias Engram.Vector.PayloadKeys

  # The payload shape a release writes. Bumping it makes
  # `Engram.Workers.ReconcileNotePayloads` bring every note's points to the new
  # shape, with no embedder call and no operator step. A note whose stamp
  # (`note_index_state.payload_version`) is NULL was written before the stamp
  # existed, which is `@baseline`; stamps are compared with `<`, so a newer
  # stamp is current and a rollback rebuilds nothing.
  #
  # 6: every v5 point carries `n`, its note row id (immutable chunk index,
  # Engram#2263). The parked folder-row-id meaning of v6 above is retired:
  # `build/2` is still not wired to any writer.
  @baseline 5
  @version 6

  @doc "The payload version this release writes (test builds: `:payload_version` override)."
  @spec version() :: pos_integer()
  def version, do: ServiceConfig.get(:payload_version, @version)

  @doc """
  Stamps `note_id`'s points as written with `version/0`
  (`note_index_state.payload_version`), never lowering a newer stamp. With
  `hash:`, only while the note row holds that `payload_hash` (an index pass
  whose compare-and-set stamp missed must not vouch for the version either).
  Runs in the caller's tenant transaction.
  """
  @spec stamp(Ecto.UUID.t(), keyword()) :: :ok
  def stamp(note_id, opts \\ []) do
    version = version()

    query =
      from(s in NoteIndexState,
        where: s.note_id == ^note_id,
        where: is_nil(s.payload_version) or s.payload_version < ^version
      )

    query =
      case Keyword.fetch(opts, :hash) do
        {:ok, hash} ->
          held = from(n in Note, where: n.id == ^note_id and n.payload_hash == ^hash, select: 1)
          where(query, exists(held))

        :error ->
          query
      end

    {_, _} = Repo.update_all(query, set: [payload_version: version])
    :ok
  end

  @doc "The version of a note whose stamp is NULL: the shape before the stamp existed."
  @spec baseline() :: 5
  def baseline, do: @baseline

  @doc "The v6 payload for a note and its extracted fields."
  @spec build(map(), FlatFields.t()) :: %{String.t() => term()}
  def build(note, flat) do
    note
    |> PayloadV5.build(flat)
    |> put_folder(Map.get(note, :folder_ref_id))
    |> sort_attrs()
  end

  @doc """
  The same payload from the note row and its `note_attrs` rows, no body.
  `filter_key` is the owning account's filter key: only needed to tell
  whether the stored status is the default `stable` (omitted from the payload).
  """
  @spec build_from_rows(map(), [map()], binary()) :: %{String.t() => term()}
  def build_from_rows(note, rows, filter_key), do: build(note, flat_from_rows(rows, filter_key))

  @doc """
  `build_from_rows/3`, or `build/2` on `extract.()` when the rows cannot be
  trusted: the note has none, or they are not provably from its current text.

  `note_attrs` rows are rewritten only by an index pass, while the note row
  (`type_hmac`, `tags_hmac`, times) moves on every edit. A pass that finished
  on the current text stamps `embed_hash = content_hash` (and an edit clears
  it), so the rows are used only when `fresh?/1` holds. Otherwise the caller's
  extraction (which decrypts the body) answers: slower, never stale.
  """
  @spec from_rows_or_extract(map(), [map()], binary(), (-> FlatFields.t())) ::
          %{String.t() => term()}
  def from_rows_or_extract(note, rows, filter_key, extract) do
    if rows != [] and fresh?(note),
      do: build_from_rows(note, rows, filter_key),
      else: build(note, extract.())
  end

  @doc "Whether the note's `note_attrs` rows come from an index pass on its current text."
  @spec fresh?(map()) :: boolean()
  def fresh?(note) do
    hash = Map.get(note, :embed_hash)
    hash != nil and hash == Map.get(note, :content_hash)
  end

  defp put_folder(payload, ref_id) do
    payload = Map.delete(payload, PayloadKeys.short(:folder_id))

    if ref_id,
      do: Map.put(payload, PayloadKeys.short(:folder_id), FilterId.uuid(to_string(ref_id))),
      else: payload
  end

  defp sort_attrs(payload) do
    case payload do
      %{"fa" => fa} -> %{payload | "fa" => Enum.sort(fa)}
      _ -> payload
    end
  end

  # The inverse of `FlatFields.attr_rows/2`. A user-added key's `key_id` is its
  # own dictionary id, so `key_ids` maps each id to itself.
  defp flat_from_rows(rows, filter_key) do
    by_key = rows |> Enum.sort_by(&{&1.key_id, &1.ord}) |> Enum.group_by(& &1.key_id)
    named = FrontmatterKeys.named()
    reserved = MapSet.new(Map.values(named))
    col = fn field, c -> for r <- Map.get(by_key, named[field], []), do: Map.fetch!(r, c) end
    first = fn field, c -> field |> col.(c) |> List.first() end

    user = for {id, rs} <- by_key, not MapSet.member?(reserved, id), r <- rs, do: r
    status_hmac = first.(:status, :h)

    %{
      FlatFields.empty()
      | status: status_text(status_hmac, filter_key),
        status_hmac: status_hmac,
        author_hmac: first.(:author, :h),
        rev_by_hmac: first.(:reviewed_by, :h),
        proj_hmac: first.(:project, :h),
        src_hmac: col.(:source, :h),
        fm_updated: first.(:updated, :d),
        fm_created: first.(:created, :d),
        fm_reviewed: first.(:reviewed, :d),
        fm_expires: first.(:expires, :d),
        fm_due: first.(:due, :d),
        fm_priority: first.(:priority, :n),
        attrs: for(%{h: h} = r when h != nil <- user, do: %{k: r.key_id, v: h}),
        nums: for(%{n: n} = r when n != nil <- user, do: %{k: r.key_id, n: n}),
        dates: for(%{d: d} = r when d != nil <- user, do: %{k: r.key_id, t: d}),
        key_ids: Map.new(user, &{&1.key_id, &1.key_id})
    }
  end

  # The payload only asks whether the status is the default; the text itself
  # is not in the rows, so any other value stands in for "not stable".
  defp status_text(nil, _filter_key), do: nil

  defp status_text(hmac, filter_key),
    do: if(hmac == FilterId.value_hmac(filter_key, "stable"), do: "stable", else: "?")
end
