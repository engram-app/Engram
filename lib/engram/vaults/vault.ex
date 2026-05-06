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
    field :encrypted, :boolean, default: false
    field :encrypted_at, :utc_datetime_usec
    field :encryption_status, :string, default: "none"
    field :decrypt_requested_at, :utc_datetime_usec
    field :last_toggle_at, :utc_datetime_usec
    field :name_ciphertext, :binary
    field :name_nonce, :binary
    field :name_hmac, :binary

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

  @doc """
  Updates only the `encryption_status` field of a vault. Used for state transitions
  between "none", "encrypting", "encrypted", "decrypting".
  """
  def update_status(%__MODULE__{} = vault, status) when is_binary(status) do
    vault
    |> Ecto.Changeset.change(%{encryption_status: status})
    |> Engram.Repo.update()
  end
end
