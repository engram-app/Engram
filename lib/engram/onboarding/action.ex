defmodule Engram.Onboarding.Action do
  @moduledoc """
  Insert-only event log of user-completed onboarding milestones. One row
  per (user_id, action). See spec
  docs/superpowers/specs/2026-05-30-ftux-foundation-design.md for the enum
  semantics.
  """

  use Ecto.Schema
  import Ecto.Changeset

  # Default integer (bigserial) PK — matches every other per-user table.
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @actions ~w(
    tour_offered_taken
    tour_offered_skipped
    tour_completed
    first_vault_created
    plugin_connected
    ai_connected
  )

  schema "onboarding_actions" do
    field :user_id, :integer
    field :action, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  def actions, do: @actions

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:user_id, :action, :metadata])
    |> validate_required([:user_id, :action])
    |> validate_inclusion(:action, @actions)
    |> unique_constraint([:user_id, :action], name: :onboarding_actions_user_id_action_index)
  end
end
