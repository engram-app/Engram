defmodule Engram.Attachments.Attachment do
  use Ecto.Schema
  import Ecto.Changeset

  @max_attachment_bytes 5 * 1024 * 1024

  schema "attachments" do
    # Phase B.3: path is virtual — populated by maybe_decrypt_attachment_fields/2.
    # Persisted form is path_ciphertext + path_nonce + path_hmac.
    field :path, :string, virtual: true
    field :path_ciphertext, :binary
    field :path_nonce, :binary
    field :path_hmac, :binary
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
    # T3.4 / H5 — DEK version this row's ciphertext was wrapped under.
    field :dek_version, :integer, default: 1
    field :content_nonce, :binary

    belongs_to :user, Engram.Accounts.User
    belongs_to :vault, Engram.Vaults.Vault

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :path_ciphertext,
      :path_nonce,
      :path_hmac,
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
    |> validate_required([
      :user_id,
      :vault_id,
      :content_hash,
      :mime_type,
      :size_bytes,
      :path_ciphertext,
      :path_nonce,
      :path_hmac
    ])
    |> validate_inclusion(:encryption_version, [1])
    |> validate_number(:size_bytes, less_than_or_equal_to: @max_attachment_bytes)
    |> validate_required(:content_nonce)
    |> unique_constraint([:user_id, :vault_id, :path_hmac],
      name: :attachments_user_id_vault_id_path_hmac_index
    )
  end

  def max_attachment_bytes, do: @max_attachment_bytes
end
