defmodule Mix.Tasks.Engram.PrepareDatabase do
  @shortdoc "Idempotent cluster bootstrap (engram_app role + DEFAULT PRIVILEGES)"

  @moduledoc """
  Mix task wrapper around `Engram.Release.prepare_database/0`.

  Used by the `ecto.setup` and `test` aliases in `mix.exs` so dev/CI
  reach the same cluster-bootstrap code path as prod (where
  `entrypoint.sh` calls the release task directly).

      mix engram.prepare_database
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    # Don't ensure_all_started — that boots Phoenix/Oban/etc, which
    # `mix test` and ecto aliases do not want. Engram.Release uses
    # `Ecto.Migrator.with_repo/2` to start just the Repo for the
    # duration of the task.
    Engram.Release.prepare_database()
  end
end
