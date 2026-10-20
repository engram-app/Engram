defmodule Engram.Attachments.Upload do
  @moduledoc """
  One in-flight chunked attachment upload (`Engram.Attachments.Uploads`).
  The row id is the `upload_id` bound into every segment's AAD.
  """
  use Engram.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @fields [
    :user_id,
    :vault_id,
    :attachment_id,
    :path_hmac,
    :path_ciphertext,
    :path_nonce,
    :mime_type,
    :size_bytes,
    :mtime,
    :part_size,
    :part_count,
    :storage_key,
    :s3_upload_id,
    :wrapped_file_key,
    :file_key_nonce
  ]

  schema "attachment_uploads" do
    field :attachment_id, Ecto.UUID
    field :path_hmac, :binary
    field :path_ciphertext, :binary
    field :path_nonce, :binary
    field :mime_type, :string
    field :size_bytes, :integer
    field :mtime, :float
    field :part_size, :integer
    field :part_count, :integer
    field :storage_key, :string
    field :s3_upload_id, :string
    field :wrapped_file_key, :binary
    field :file_key_nonce, :binary
    # Part number as a string key (jsonb) => storage ETag.
    field :parts, :map, default: %{}

    belongs_to :user, Engram.Accounts.User
    belongs_to :vault, Engram.Vaults.Vault

    timestamps(type: :utc_datetime)
  end

  def changeset(upload, attrs) do
    upload
    |> cast(attrs, @fields)
    |> validate_required(@fields -- [:mtime])
    |> validate_number(:size_bytes, greater_than: 0)
  end
end
