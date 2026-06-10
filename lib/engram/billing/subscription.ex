defmodule Engram.Billing.Subscription do
  use Engram.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "subscriptions" do
    field :paddle_customer_id, :string
    field :paddle_subscription_id, :string
    field :tier, :string
    field :status, :string, default: "trialing"
    field :current_period_end, :utc_datetime
    field :custom_data, :map, default: %{}

    belongs_to :user, Engram.Accounts.User

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :user_id,
      :paddle_customer_id,
      :paddle_subscription_id,
      :tier,
      :status,
      :current_period_end,
      :custom_data
    ])
    |> validate_required([:user_id, :paddle_customer_id, :tier, :status])
    |> validate_inclusion(:tier, ~w(free starter pro))
    |> validate_inclusion(:status, ~w(trialing active past_due paused canceled))
    |> unique_constraint(:user_id)
    |> unique_constraint(:paddle_subscription_id)
  end
end
