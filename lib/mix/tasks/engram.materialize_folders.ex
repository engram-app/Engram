defmodule Mix.Tasks.Engram.MaterializeFolders do
  @shortdoc "Backfill folder_marker rows for virtual folders"

  @moduledoc """
  Materializes folder_marker rows for every virtual folder across all
  (user, vault) pairs. Idempotent. Safe to re-run.

  Usage:
      mix engram.materialize_folders        # run on all users
      mix engram.materialize_folders --user-id 42

  In a release:
      bin/engram rpc 'Engram.Notes.Materialization.run_all()'
  """

  use Mix.Task

  alias Engram.{Accounts, Vaults}
  alias Engram.Notes.Materialization

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: [user_id: :integer])

    users =
      case opts[:user_id] do
        nil -> Accounts.list_users()
        id -> [Accounts.get_user!(id)]
      end

    Enum.each(users, fn user ->
      Enum.each(Vaults.list_vaults(user), fn vault ->
        case Materialization.run(user, vault) do
          {:ok, %{inserted: i, existing: e}} ->
            IO.puts("user=#{user.id} vault=#{vault.id} inserted=#{i} existing=#{e}")

          {:error, reason} ->
            IO.puts(:stderr, "user=#{user.id} vault=#{vault.id} ERROR #{inspect(reason)}")
        end
      end)
    end)
  end
end
