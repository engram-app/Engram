defmodule Engram.Instance.InstanceSettings do
  use Engram.Schema
  import Ecto.Changeset

  @modes ~w(closed invite_only open)

  schema "instance_settings" do
    field :registration_mode, :string, default: "invite_only"
    field :bootstrap_completed_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def modes, do: @modes

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:registration_mode, :bootstrap_completed_at])
    |> validate_required([:registration_mode])
    |> validate_inclusion(:registration_mode, @modes)
  end
end
