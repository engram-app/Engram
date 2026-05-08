defmodule Engram.Vaults.Vault do
  use Ecto.Schema
  import Ecto.Changeset

  schema "vaults" do
    # Phase B.3: name is virtual — populated by maybe_decrypt_vault_fields/2.
    # Persisted form is name_ciphertext + name_nonce + name_hmac.
    field :name, :string, virtual: true
    field :description, :string
    field :slug, :string
    field :client_id, :string
    field :is_default, :boolean, default: false
    field :deleted_at, :utc_datetime
    field :name_ciphertext, :binary
    field :name_nonce, :binary
    field :name_hmac, :binary
    # T3.4 / H5 — DEK version this row's ciphertext was wrapped under.
    field :dek_version, :integer, default: 1

    belongs_to :user, Engram.Accounts.User

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  def changeset(vault, attrs) do
    vault
    |> cast(attrs, [
      :description,
      :slug,
      :client_id,
      :is_default,
      :user_id,
      :deleted_at,
      :name_ciphertext,
      :name_nonce,
      :name_hmac
    ])
    |> validate_required([
      :slug,
      :user_id,
      :name_ciphertext,
      :name_nonce,
      :name_hmac
    ])
    |> unique_constraint([:user_id, :slug], name: :vaults_user_id_slug_index)
    |> unique_constraint([:user_id, :client_id], name: :vaults_user_id_client_id_index)
  end
end
