defmodule Mix.Tasks.Engram.Migrate do
  @shortdoc "Runs the migrations, then the owner-run boot drops, as prod boot does"

  @moduledoc """
  Mix task wrapper around `Engram.Release.migrate/0`: the migrations, then
  the boot steps that run after them (`Engram.Release.FolderHashDrop`).

  Used by the `ecto.setup` and `test` aliases in `mix.exs` in place of
  `ecto.migrate`, so dev and CI reach the schema prod boot leaves.

      mix engram.migrate
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    # app.config loads config/runtime.exs (DATABASE_URL) without starting the
    # app, as `engram.prepare_database` does.
    Mix.Task.run("app.config", args)
    _ = Engram.Release.migrate()
    :ok
  end
end
