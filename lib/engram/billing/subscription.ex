defmodule Engram.Billing.Subscription do
  @moduledoc false
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
    # `occurred_at` of the newest Paddle subscription.* event applied. Paddle
    # delivers out of order; older events are skipped. NULL accepts any event.
    field :last_event_occurred_at, :utc_datetime_usec
    # `%{tier:, status:}` before a webhook update, set by `Billing` so the
    # analytics forwarder can name the change. Never persisted.
    field :previous, :map, virtual: true

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
      :custom_data,
      :last_event_occurred_at
    ])
    |> validate_required([:user_id, :paddle_customer_id, :tier, :status])
    |> validate_inclusion(:tier, ~w(free starter pro))
    |> validate_inclusion(:status, ~w(trialing active past_due paused canceled))
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id)
    |> unique_constraint(:paddle_subscription_id)
  end
end
