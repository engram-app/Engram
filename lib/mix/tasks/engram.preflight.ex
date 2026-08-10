defmodule Mix.Tasks.Engram.Preflight do
  @shortdoc "Preview pending migrations before upgrade (self-host)"
  @moduledoc """
  Prints what `Engram.Release.migrate()` is about to do on the next container
  start, via `Engram.Release.Preflight.run/0`.

  ## Usage

      mix engram.preflight

  Thin wrapper only — `Mix.Task` is unavailable in a release, so the report
  lives in `Engram.Release.Preflight`, which self-host operators call directly
  inside a running container:

      docker compose exec engram bin/engram rpc 'Engram.Release.Preflight.run()'

  Output: pending migrations with phase tags, irreversibility flags,
  estimated lock impact, and an optional rollback command (only when all
  pending migrations are reversible). See `Engram.Release.Preflight` for the
  phase tags and the lock-risk heuristic's limitations.
  """

  use Mix.Task

  alias Engram.Release.Preflight

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    Preflight.run()
  end
end
