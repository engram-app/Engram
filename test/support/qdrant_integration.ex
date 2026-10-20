defmodule Engram.QdrantIntegration do
  @moduledoc """
  Drops a real-Qdrant test collection when the test exits.

  `on_exit` runs in its own process, which does not see the test's
  per-process `:qdrant_url` override. Once a Bypass suite has deleted the
  global `:qdrant_url`, a bare `Qdrant.delete_collection/1` there goes to the
  compiled localhost:6333 default, fails, and the collection stays on CI's
  2 GB tmpfs Qdrant until it SIGBUSes. So the URL is captured now and
  re-installed inside the callback, and a failed drop fails the test.
  """

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  @spec drop_on_exit(String.t(), (-> any())) :: :ok
  def drop_on_exit(col, after_drop \\ fn -> :ok end) do
    url = ServiceConfig.get(:qdrant_url)

    ExUnit.Callbacks.on_exit(fn ->
      ServiceConfig.put_override(:qdrant_url, url)
      :ok = Qdrant.delete_collection(col)
      after_drop.()
    end)
  end
end
