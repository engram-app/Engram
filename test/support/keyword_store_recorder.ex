defmodule Engram.KeywordStoreRecorder do
  @moduledoc """
  Test `Engram.KeywordStore` backend: sends `{:keyword_store, callback, args}`
  to the test that installed it, then delegates to `QdrantSparse`, so a test
  proves a path reaches the seam without changing what it does.
  """
  @behaviour Engram.KeywordStore

  alias Engram.KeywordStore.QdrantSparse
  alias Engram.ServiceConfig

  @doc """
  Make this the keyword store for the calling test (and its `$callers`).
  `fail: reason` makes every call record, then return `{:error, reason}`.
  """
  def install(opts \\ []) do
    ServiceConfig.put_override(:keyword_store, __MODULE__)
    ServiceConfig.put_override(:keyword_store_recorder_pid, self())
    ServiceConfig.put_override(:keyword_store_recorder_fail, opts[:fail])
  end

  # Optional callbacks (`in_commit/3`) stay undefined, as on the backend it
  # delegates to.
  for {name, arity} <-
        Engram.KeywordStore.behaviour_info(:callbacks) --
          Engram.KeywordStore.behaviour_info(:optional_callbacks) do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl true
    def unquote(name)(unquote_splicing(args)) do
      record(unquote(name), unquote(args))

      case ServiceConfig.get(:keyword_store_recorder_fail) do
        nil -> apply(QdrantSparse, unquote(name), unquote(args))
        reason -> {:error, reason}
      end
    end
  end

  defp record(name, args) do
    case ServiceConfig.get(:keyword_store_recorder_pid) do
      pid when is_pid(pid) -> send(pid, {:keyword_store, name, args})
      _ -> :ok
    end
  end
end
