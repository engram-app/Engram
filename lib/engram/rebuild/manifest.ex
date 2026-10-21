defmodule Engram.Rebuild.Manifest do
  @moduledoc "One stale note's dry-run estimate (`Engram.Rebuild`). Tenant table."
  use Ecto.Schema

  @primary_key {:note_id, :binary_id, autogenerate: false}
  schema "rebuild_manifest" do
    field :user_id, :binary_id
    field :vault_id, :binary_id
    field :est_tokens, :integer
    field :new_points, :integer
    field :reused_points, :integer
    field :mean_pooled_points, :integer
    field :dl_sum, :integer
    field :dl_count, :integer
    field :planned_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end
end
