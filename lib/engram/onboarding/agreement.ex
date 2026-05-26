defmodule Engram.Onboarding.Agreement do
  @moduledoc """
  Records a user's acceptance of a versioned legal document (Terms of
  Service, Privacy Policy, etc.). One row per user per accepted version.
  Tenant-scoped via RLS — must be queried inside `Repo.with_tenant/2`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "user_agreements" do
    field :document, :string
    field :version, :string
    field :accepted_at, :utc_datetime
    field :ip_address, :string
    field :user_agent, :string
    field :content_hash, :string

    belongs_to :user, Engram.Accounts.User
  end

  def changeset(agreement, attrs) do
    agreement
    |> cast(attrs, [
      :user_id,
      :document,
      :version,
      :accepted_at,
      :ip_address,
      :user_agent,
      :content_hash
    ])
    |> validate_required([:user_id, :document, :version, :accepted_at])
  end
end
