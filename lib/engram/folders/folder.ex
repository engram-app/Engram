defmodule Engram.Folders.Folder do
  @moduledoc """
  A folder as a row (migration 20261027000000): an id, its parent, and its own
  name, so a child points at it by `folder_ref_id` instead of repeating the
  path. `parent_id` nil is the vault root (there is no root row).

  The name is one path SEGMENT, encrypted under the owning account's DEK like
  `notes.folder_ciphertext` (AAD `Crypto.aad_for_row(:folders, :name, id)`).
  `full_path_hmac` is transitional: the HMAC of the whole path, equal to
  `notes.folder_hmac`, which the `notes_set_folder_ref` trigger matches on.

  Filled by the `DataMigrations.FolderTable` backfill; no reader or writer
  uses it yet.
  """
  use Engram.Schema

  schema "folders" do
    field :user_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    field :parent_id, Ecto.UUID
    field :name_ciphertext, :binary
    field :name_nonce, :binary
    field :name_hmac, :binary
    field :full_path_hmac, :binary
    field :dek_version, :integer
    field :explicit, :boolean, default: false
    field :deleted_at, :utc_datetime_usec
    field :delete_op_id, Ecto.UUID

    timestamps(type: :utc_datetime_usec)
  end
end
