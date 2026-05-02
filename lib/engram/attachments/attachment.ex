defmodule Engram.Attachments.Attachment do
  use Ecto.Schema
  import Ecto.Changeset

  @max_attachment_bytes 5 * 1024 * 1024

  schema "attachments" do
    field :path, :string
    # Decoded plaintext is materialized into this virtual field by the read
    # path (`Engram.Attachments.get_attachment/3`). It never persists; the
    # actual ciphertext lives in S3-compatible object storage.
    field :content, :binary, virtual: true
    field :content_hash, :string
    field :mime_type, :string
    field :size_bytes, :integer
    field :mtime, :float
    field :storage_key, :string
    field :deleted_at, :utc_datetime
    field :encryption_version, :integer, default: 1
    field :content_nonce, :binary

    belongs_to :user, Engram.Accounts.User
    belongs_to :vault, Engram.Vaults.Vault

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :path,
      :content_hash,
      :mime_type,
      :size_bytes,
      :mtime,
      :user_id,
      :vault_id,
      :storage_key,
      :deleted_at,
      :encryption_version,
      :content_nonce
    ])
    |> validate_required([:path, :user_id, :vault_id, :content_hash, :mime_type, :size_bytes])
    |> validate_inclusion(:encryption_version, [1])
    |> validate_number(:size_bytes, less_than_or_equal_to: @max_attachment_bytes)
    |> validate_required(:content_nonce)
    |> unique_constraint([:user_id, :vault_id, :path],
      name: :attachments_user_vault_path_active_index
    )
  end

  def max_attachment_bytes, do: @max_attachment_bytes
end
