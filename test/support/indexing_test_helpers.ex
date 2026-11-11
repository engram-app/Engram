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

  # A note's misses past one pass's embed budget finish over several passes
  # (`{:error, :embed_continues}`, EmbedNote snoozes and runs the next).
  @max_passes 20

  @doc """
  Runs `fun` (one index pass) again while it returns
  `{:error, :embed_continues}`, at most #{@max_passes} times, and returns
  every pass's result in order: the last is the one that finished (or the
  last continue, if the cap hit). `fun` may return `{result, extra}` to keep
  per-pass data alongside; `result` is what is checked.
  """
  def index_passes(fun) do
    Enum.reduce_while(1..@max_passes, [], fn _, acc ->
      pass = fun.()
      if continues?(pass), do: {:cont, [pass | acc]}, else: {:halt, [pass | acc]}
    end)
    |> Enum.reverse()
  end

  @doc "The result of the pass that finished (`index_passes/1`'s last)."
  def until_done(fun), do: fun |> index_passes() |> List.last()

  defp continues?({:error, :embed_continues}), do: true
  defp continues?({{:error, :embed_continues}, _extra}), do: true
  defp continues?(_), do: false
end
