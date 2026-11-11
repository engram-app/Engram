defmodule Engram.MigrationFile do
  @moduledoc """
  Loads a migration module for a test, once per VM. `mix test` migrates a
  fresh database in the same VM first, so the module can already be loaded;
  compiling the file again warns "redefining module", which fails
  `--warnings-as-errors`. Every test that needs a migration's module goes
  through `load!/1`.
  """

  @dir "priv/repo/migrations"

  @doc "The module of `file` (a name in #{@dir}), compiled only if not loaded."
  @spec load!(String.t()) :: module()
  def load!(file) do
    path = Path.join(@dir, file)
    [_, name] = Regex.run(~r/^defmodule\s+([\w.]+)/m, File.read!(path))

    case loaded(name) do
      nil ->
        [{mod, _}] = Code.compile_file(path)
        mod

      mod ->
        mod
    end
  end

  # safe_concat raises when the atom does not exist: never loaded.
  defp loaded(name) do
    mod = Module.safe_concat([name])
    if Code.ensure_loaded?(mod), do: mod
  rescue
    ArgumentError -> nil
  end
end
