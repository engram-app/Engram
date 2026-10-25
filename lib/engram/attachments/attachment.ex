defmodule Engram.Attachments.Attachment do
  @moduledoc false
  use Engram.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "attachments" do
    # Phase B.3: path is virtual — populated by maybe_decrypt_attachment_fields/2.
    # Persisted form is path_ciphertext + path_nonce + path_hmac.
    field :path, :string, virtual: true, redact: true
    field :path_ciphertext, :binary
    field :path_nonce, :binary
    field :path_hmac, :binary
    # Links foundation (Task 1/4) — HMAC of the lowercased basename (no
    # extension stripping for non-note files). Nullable until backfilled.
    field :basename_hmac, :binary
    # Link resolution keys (`Engram.Links.path_keys/3`), trusted only while the stamp matches.
    field :path_ci_hmac, :binary
    field :path_length, :integer
    field :link_keys_stamp, :binary
    # Decoded plaintext is materialized into this virtual field by the read
    # path (`Engram.Attachments.get_attachment/3`). It never persists; the
    # actual ciphertext lives in S3-compatible object storage.
    field :content, :binary, virtual: true, redact: true
    field :content_hash, :string
    field :mime_type, :string
    field :size_bytes, :integer
    field :mtime, :float
    field :storage_key, :string
    field :deleted_at, :utc_datetime
    # The undoable delete that tombstoned this row (#609), restored by
    # `Engram.Folders.restore_op/3`. Nil on live rows and move tombstones.
    field :delete_op_id, Ecto.UUID
    # Set while `Engram.Workers.AttachmentBlobGC` owns this tombstone's blob
    # delete; cleared when it finishes (a stale stamp is re-claimed).
    field :blob_gc_claimed_at, :utc_datetime_usec
    # Sync change-log seq (monotonic per vault). Stamped on every write.
    field :seq, :integer
    # Sync resurrection-parity counter (mirrors notes.version). Starts at 1 on
    # insert, +1 on every content update. NOT bumped on soft-delete — deletes
    # are conveyed by the `deleted_at` tombstone, not version.
    field :version, :integer, default: 1
    field :encryption_version, :integer, default: 1
    # T3.4 / H5 — DEK version this row's ciphertext was wrapped under.
    field :dek_version, :integer, default: 1
    # T3.7 — target DEK version for in-progress rotation; nil when idle.
    field :dek_version_pending, :integer
    field :content_nonce, :binary
    # Format v2 (`Engram.Attachments.SegmentedCipher`): content sealed in
    # segments under a per-file key; the DEK wraps only that key.
    field :wrapped_file_key, :binary
    field :file_key_nonce, :binary
    field :upload_id, Ecto.UUID
    field :segment_size, :integer
    field :segment_count, :integer

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
      :basename_hmac,
      :path_ci_hmac,
      :path_length,
      :link_keys_stamp,
      :content_hash,
      :mime_type,
      :size_bytes,
      :mtime,
      :user_id,
      :vault_id,
      :storage_key,
      :deleted_at,
      :seq,
      :version,
      :encryption_version,
      :dek_version,
      :dek_version_pending,
      :content_nonce,
      :wrapped_file_key,
      :file_key_nonce,
      :upload_id,
      :segment_size,
      :segment_count
    ])
    |> validate_required([
      :user_id,
      :vault_id,
      :content_hash,
      :mime_type,
      :size_bytes
    ])
    |> validate_encrypted(:path, [:path_ciphertext, :path_nonce, :path_hmac])
    |> validate_content_format()
    |> validate_inclusion(:encryption_version, [1, 2])
    |> unique_constraint([:user_id, :vault_id, :path_hmac],
      name: :attachments_user_id_vault_id_path_hmac_index
    )
  end

  @segmented_fields [
    :wrapped_file_key,
    :file_key_nonce,
    :upload_id,
    :segment_size,
    :segment_count
  ]

  # v1 seals the whole object under the DEK (`content_nonce`); v2 is
  # segmented and carries the wrapped file key instead, never both.
  defp validate_content_format(changeset) do
    if get_field(changeset, :encryption_version) == 2 do
      changeset
      |> validate_encrypted(:content, @segmented_fields)
      |> validate_number(:segment_size, greater_than: 0)
      |> validate_number(:segment_count, greater_than: 0)
      |> then(fn cs ->
        if get_field(cs, :content_nonce) in [nil, ""],
          do: cs,
          else: add_error(cs, :content_nonce, "must be blank for segmented content")
      end)
    else
      validate_encrypted(changeset, :content, [:content_nonce])
    end
  end

  # Encryption invariant: the ciphertext columns for `public_field` must be
  # populated. They are derived server-side from the client-supplied value, so
  # a missing column means that value was absent — error on the public field
  # name rather than leaking internal column names into 422 bodies (same
  # contract as Engram.Vaults.Vault.validate_encrypted_name/1).
  defp validate_encrypted(changeset, public_field, internal_fields) do
    if Enum.all?(internal_fields, &(get_field(changeset, &1) not in [nil, ""])) do
      changeset
    else
      add_error(changeset, public_field, "can't be blank", validation: :required)
    end
  end
end
