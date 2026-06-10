defmodule Engram.Onboarding.Action do
  @moduledoc """
  Insert-only event log of user-completed onboarding milestones. One row
  per (user_id, action). See spec
  docs/superpowers/specs/2026-05-30-ftux-foundation-design.md for the enum
  semantics.
  """

  use Engram.Schema
  import Ecto.Changeset

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

  # Parameterized dismiss actions: `dismissed:<slug>` where slug starts with
  # a lowercase letter and contains only lowercase letters, digits, and
  # underscores. Distinct from the static milestone catalog above so we can
  # add new dismissable steps from the frontend without backend changes.
  @dismissed_slug_pattern ~r/^dismissed:[a-z][a-z0-9_]{0,47}$/

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:user_id, :action, :metadata])
    |> validate_required([:user_id, :action])
    |> validate_action()
    |> unique_constraint([:user_id, :action], name: :onboarding_actions_user_id_action_index)
  end

  defp validate_action(changeset) do
    case fetch_change(changeset, :action) do
      {:ok, value} when is_binary(value) ->
        cond do
          value in @actions -> changeset
          Regex.match?(@dismissed_slug_pattern, value) -> changeset
          true -> add_error(changeset, :action, "is invalid")
        end

      _ ->
        changeset
    end
  end
end
