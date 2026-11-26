defmodule Engram.KeywordStoreRecorder do
  @moduledoc """
  Test `Engram.KeywordStore` backend: sends `{:keyword_store, callback, args}`
  to the test that installed it, then delegates to `QdrantSparse`, so a test
  proves a path reaches the seam without changing what it does.
  """
  @behaviour Engram.KeywordStore

  alias Engram.KeywordStore.QdrantSparse
  alias Engram.ServiceConfig

  @doc "Make this the keyword store for the calling test (and its `$callers`)."
  def install do
    ServiceConfig.put_override(:keyword_store, __MODULE__)
    ServiceConfig.put_override(:keyword_store_recorder_pid, self())
  end

  for {name, arity} <- Engram.KeywordStore.behaviour_info(:callbacks) do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl true
    def unquote(name)(unquote_splicing(args)) do
      record(unquote(name), unquote(args))
      apply(QdrantSparse, unquote(name), unquote(args))
    end
  end

  defp record(name, args) do
    case ServiceConfig.get(:keyword_store_recorder_pid) do
      pid when is_pid(pid) -> send(pid, {:keyword_store, name, args})
      _ -> :ok
    end
  end
end
