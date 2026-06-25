defmodule Engram.ObanFacade do
  @moduledoc """
  Thin behaviour over the Oban control calls the app makes directly, so
  shutdown/drain logic can be unit-tested without a running Oban cluster.

  Production default is `Oban` itself (resolved in `Engram.Drainer`); tests
  swap in a Mox mock to assert call options like `local_only:`.
  """

  @callback pause_all_queues(name :: term(), opts :: keyword()) :: :ok
end
