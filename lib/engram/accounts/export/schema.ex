defmodule Engram.Accounts.Export.Schema do
  @moduledoc """
  Ecto schema for the `account_exports` table.

  Statuses: pending → running → ready → expired. (or failed at any point.)
  Reasons: user_request | pre_delete | inactivity.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w[pending running ready failed expired]a
  @reasons ~w[user_request pre_delete inactivity]a

  schema "account_exports" do
    field :status, Ecto.Enum, values: @statuses
    field :s3_keys, {:array, :map}, default: []
    field :s3_upload_ids, {:array, :map}, default: []
    field :size_bytes, :integer
    field :error_reason, :string
    field :ready_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :downloaded_at, :utc_datetime_usec
    field :reason, Ecto.Enum, values: @reasons

    belongs_to :user, Engram.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [
      :user_id,
      :status,
      :s3_keys,
      :s3_upload_ids,
      :size_bytes,
      :error_reason,
      :ready_at,
      :expires_at,
      :downloaded_at,
      :reason
    ])
    |> validate_required([:user_id, :status, :reason])
    |> unique_constraint(:user_id, name: :account_exports_one_active_per_user)
  end

  def statuses, do: @statuses
  def reasons, do: @reasons
end
