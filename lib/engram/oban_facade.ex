defmodule Engram.ObanFacade do
  @moduledoc """
  Thin behaviour over the Oban calls the app makes directly, so shutdown/drain
  logic can be unit-tested without a running Oban cluster, and an insert
  failure can be injected without DDL on the shared `oban_jobs` table.

  Production default is `Oban` itself (resolved via the `:oban_facade` app
  env); tests swap in a Mox mock to assert call options like `local_only:`.
  """

  @callback pause_all_queues(name :: term(), opts :: keyword()) :: :ok
  @callback insert_all(changesets :: [Ecto.Changeset.t()]) :: [Oban.Job.t()]
end
