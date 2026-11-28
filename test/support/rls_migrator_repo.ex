defmodule Engram.RlsMigratorRepo do
  @moduledoc """
  A repo for boot-step tests: `Engram.Repo`, except that each checkout runs as
  `engram_app` (no SUPERUSER, no BYPASSRLS, no tenant set), so a read of a
  FORCE RLS table sees no rows, as prod's migrator does (the RDS master owns
  the tables but is not a superuser). The suite's own login is a superuser
  and would see every row.
  """

  alias Engram.Repo

  def checkout(fun, opts) do
    Repo.checkout(
      fn ->
        Repo.query!("SET SESSION AUTHORIZATION engram_app")

        try do
          fun.()
        after
          Repo.query!("RESET SESSION AUTHORIZATION")
        end
      end,
      opts
    )
  end

  defdelegate query!(sql), to: Repo
  defdelegate query!(sql, params, opts), to: Repo
  defdelegate query(sql, params, opts), to: Repo
end
