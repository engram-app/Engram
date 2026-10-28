defmodule Engram.InterleaveHook do
  @moduledoc """
  Test-only seam that parks a write at a named point so a test can change the
  database in between (`Engram.CheckpointInterleave`). Reads
  `:checkpoint_interleave_hook`, which is nil in every environment that does
  not arm it, so outside those tests this is one `Application.get_env`.

  A hook ignores points it does not recognise, so arming one module's point
  never fires another's.
  """

  @spec run(atom()) :: :ok
  def run(point) do
    case Application.get_env(:engram, :checkpoint_interleave_hook) do
      nil -> :ok
      fun when is_function(fun, 1) -> _ = fun.(point)
    end

    :ok
  end
end
