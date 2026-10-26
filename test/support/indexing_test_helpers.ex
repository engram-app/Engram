defmodule Engram.IndexingTestHelpers do
  @moduledoc """
  Shared setup for tests that drive `Engram.Indexing` passes.

  Every pass now reads and fills the per-user vector cache
  (`Engram.Indexing.VectorCache`) and applies the owner's per-note points cap,
  so a test that needs a text sent to the embedder again, or a note indexed
  one point a chunk, says so with these.
  """

  @doc """
  Empties the vector cache, so every text a pass does not reuse from its own
  rows is sent to the embedder (as if never embedded for this user).
  """
  def clear_vector_cache, do: Engram.Repo.query!("DELETE FROM embedding_cache")

  @doc """
  Runs `fun` with plan limits unenforced: no per-note points cap, so a note
  indexes one point a chunk. Restores enforcement (on in `config/test.exs`).
  """
  def without_limits(fun) do
    Application.put_env(:engram, :limits_enforced, false)

    try do
      fun.()
    after
      Application.put_env(:engram, :limits_enforced, true)
    end
  end
end
