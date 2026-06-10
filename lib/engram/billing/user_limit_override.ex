defmodule Engram.Billing.UserLimitOverride do
  @moduledoc """
  Per-(user, key) limit override with audit fields. Replaces
  `Engram.Billing.UserOverride` (single-blob-per-user schema).

  Value is wrapped as `%{"v" => actual_value}` so JSONB can hold
  bare integers/booleans without an object-root constraint and so
  we can extend with metadata later without re-migrating.
  """
  use Engram.Schema
  import Ecto.Changeset

  alias Engram.Billing.LimitKeys

  schema "user_limit_overrides" do
    field :key, :string
    field :value, :map
    field :reason, :string
    field :set_by, :string
    field :set_at, :utc_datetime
    field :expires_at, :utc_datetime
    belongs_to :user, Engram.Accounts.User
  end

  @required ~w(user_id key value reason set_by)a
  @optional ~w(set_at expires_at)a

  def changeset(override, attrs) do
    override
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_change(:key, fn :key, k ->
      if LimitKeys.defined?(safe_atom(k)) do
        []
      else
        [key: "not a known limit key"]
      end
    end)
    |> unique_constraint([:user_id, :key], name: :user_limit_overrides_user_id_key_index)
  end

  defp safe_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> :__unknown__
  end

  defp safe_atom(_), do: :__unknown__
end
