defmodule Engram.Notes.Note do
  use Ecto.Schema
  import Ecto.Changeset

  schema "notes" do
    field :path, :string
    field :title, :string
    field :content, :string
    field :folder, :string
    field :tags, {:array, :string}, default: []
    field :version, :integer, default: 1
    field :content_hash, :string
    field :embed_hash, :string
    field :mtime, :float
    field :deleted_at, :utc_datetime_usec
    field :content_ciphertext, :binary
    field :content_nonce, :binary
    field :title_ciphertext, :binary
    field :title_nonce, :binary
    field :tags_ciphertext, :binary
    field :tags_nonce, :binary
    field :path_ciphertext, :binary
    field :path_nonce, :binary
    field :path_hmac, :binary
    field :folder_ciphertext, :binary
    field :folder_nonce, :binary
    field :folder_hmac, :binary
    field :tags_hmac, {:array, :binary}, default: []

    belongs_to :user, Engram.Accounts.User
    belongs_to :vault, Engram.Vaults.Vault
    has_many :chunks, Engram.Notes.Chunk

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @encryption_fields [
    :content_ciphertext,
    :content_nonce,
    :title_ciphertext,
    :title_nonce,
    :tags_ciphertext,
    :tags_nonce,
    :path_ciphertext,
    :path_nonce,
    :path_hmac,
    :folder_ciphertext,
    :folder_nonce,
    :folder_hmac,
    :tags_hmac
  ]

  def changeset(note, attrs) do
    note
    |> cast(
      attrs,
      [
        :path,
        :title,
        :content,
        :folder,
        :tags,
        :version,
        :content_hash,
        :mtime,
        :user_id,
        :vault_id,
        :deleted_at
      ] ++ @encryption_fields,
      empty_values: []
    )
    |> validate_required([:path, :user_id, :vault_id])
    |> default_content()
    |> unique_constraint([:user_id, :vault_id, :path], name: :notes_user_vault_path_active_index)
  end

  defp default_content(changeset) do
    if get_field(changeset, :content) == nil do
      put_change(changeset, :content, "")
    else
      changeset
    end
  end

  def encryption_changeset(note, attrs) do
    note
    |> cast(attrs, [
      :content,
      :content_ciphertext,
      :content_nonce,
      :title,
      :title_ciphertext,
      :title_nonce,
      :tags,
      :tags_ciphertext,
      :tags_nonce
    ])
  end
end
