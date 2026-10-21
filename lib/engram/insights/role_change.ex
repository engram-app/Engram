defmodule Engram.Insights.RoleChange do
  @moduledoc """
  A grant or revoke of a role (`role_change_log`). `scope` is "platform" for
  `users.role`; team roles will log here with their own scope. `actor_id` is
  nil for a grant made from the release console.
  """
  use Engram.Schema

  schema "role_change_log" do
    field :actor_id, Ecto.UUID
    field :target_user_id, Ecto.UUID
    field :action, :string
    field :scope, :string
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end
end
