defmodule Engram.Test.SourceLint do
  @moduledoc """
  Shared helpers for static-source lint tests.

  Used by encryption tier-3 lint tests to walk `lib/` (or any subtree) and
  flag forbidden patterns at PR-CI time. Centralized so that adding a new
  lint test does not duplicate the directory walker / comment skipper.
  """

  @doc "Recursively collect every `*.ex` file under `dir`."
  @spec walk_ex_files(Path.t()) :: [Path.t()]
  def walk_ex_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)

      cond do
        File.dir?(path) -> walk_ex_files(path)
        String.ends_with?(entry, ".ex") -> [path]
        true -> []
      end
    end)
  end

  @doc """
  True when the line starts (after optional leading whitespace) with `#`.

  Used so that lint tests can document the patterns they ban *inside* the
  test file's own code without self-tripping the lint.
  """
  @spec commented?(String.t()) :: boolean()
  def commented?(line), do: Regex.match?(~r/^\s*#/, line)
end
