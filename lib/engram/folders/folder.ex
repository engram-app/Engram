defmodule Engram.Folders.Folder do
  @moduledoc """
  A folder as a row (migration 20261029000000): an id, its parent, and its own
  name, so a child points at it by `folder_ref_id` instead of repeating the
  path. `parent_id` nil is the vault root (there is no root row).

  The name is one path SEGMENT, encrypted under the owning account's DEK like
  `notes.folder_ciphertext` (AAD `Crypto.aad_for_row(:folders, :name, id)`).
  `full_path_hmac` is the HMAC of the whole path, equal to a marker's
  `folder_hmac` (and a note's, while note writes still set it).

  Filled by the `DataMigrations.FolderTable` backfill; no reader or writer
  uses it yet.
  """
  use Engram.Schema

  # A folder segment's HMAC lives in its own domain, so it never equals a
  # note's `path_hmac` or a `folder_hmac` (a full path).
  @name_domain "folder-name\0"

  @ci_domain "folder-name-ci\0"

  @doc "The `name_hmac` of one path segment under a user's filter key."
  @spec name_hmac(binary(), String.t()) :: binary()
  def name_hmac(filter_key, segment),
    do: Engram.Crypto.hmac_field(filter_key, @name_domain <> segment)

  @doc """
  `name_ci_hmac`: the casefolded key two sibling names that differ only by
  case share (O(1) folder rename plan S2; `Engram.Notes.Name.ci_hmac/2` for
  notes). Read by nothing until S3.
  """
  @spec name_ci_hmac(binary(), String.t()) :: binary()
  def name_ci_hmac(filter_key, segment),
    do: Engram.Crypto.hmac_field(filter_key, @ci_domain <> String.downcase(segment))

  @doc """
  The name hashes of a row whose `name_ciphertext` encrypts `segment` under
  `name_nonce`: `name_hmac`, `name_ci_hmac` and the `name_stamp` that says the
  second was computed from that ciphertext (`Engram.Notes.Name.stamp/1`; a
  writer that renames without it, the previous release, leaves a mismatch the
  `NoteName` ledger heals). Every folder name writer splices these in.
  """
  @spec name_keys(binary(), String.t(), binary()) :: keyword()
  def name_keys(filter_key, segment, name_nonce),
    do: [
      name_hmac: name_hmac(filter_key, segment),
      name_ci_hmac: name_ci_hmac(filter_key, segment),
      name_stamp: Engram.Notes.Name.stamp(name_nonce)
    ]

  @type t :: %__MODULE__{}

  schema "folders" do
    field :user_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    field :parent_id, Ecto.UUID
    field :name_ciphertext, :binary
    field :name_nonce, :binary
    field :name_hmac, :binary
    field :name_ci_hmac, :binary
    field :name_stamp, :binary
    # The vault change seq of the row's last structural change, and whether
    # that change also rewrote the folder's notes (every writer before S5
    # does). Written from S5 on; nothing reads them yet.
    field :seq, :integer
    field :notes_cascaded, :boolean, default: true
    field :full_path_hmac, :binary
    field :dek_version, :integer
    field :explicit, :boolean, default: false
    field :deleted_at, :utc_datetime_usec
    field :delete_op_id, Ecto.UUID
    # `Engram.Search.NameTerms`: `<<version>> <> name_hmac` its terms were written for.
    field :name_terms_stamp, :binary

    timestamps(type: :utc_datetime_usec)
  end
end
