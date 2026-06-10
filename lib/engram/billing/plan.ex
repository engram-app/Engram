defmodule Engram.Billing.Plan do
  use Engram.Schema
  import Ecto.Changeset

  schema "plans" do
    field :name, :string
    field :limits, :map, default: %{}

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [:name, :limits])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
