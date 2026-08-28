defmodule Engram.Test.ObanWorkers do
  @moduledoc """
  Enumerates every module in `:engram` that implements `Oban.Worker`.

  Used by the guard tests that assert cross-cutting properties of the worker
  set — that each one targets a registered queue, and that each one defines a
  finite `timeout/1`. Those guards exist to catch a NEW worker that silently
  breaks the invariant, so they cannot be driven off a hand-kept list.

  Reads the `Attr` chunk straight off each `.beam` rather than calling
  `Code.ensure_loaded?/1` across all ~5000 modules. The code server is a single
  process: under the full async suite that call serialises behind every other
  test and blows ExUnit's 60s per-test timeout, which is a flake that looks
  exactly like a real failure. Only the handful that turn out to be workers get
  loaded, so `timeout/1` and `__opts__/0` are callable on the result.
  """

  @doc "All `Oban.Worker` modules in the `:engram` application, loaded."
  @spec all() :: [module()]
  def all do
    # `Application.app_dir/2`, not `:code.lib_dir/2` — the latter is deprecated
    # on newer OTP and CI compiles with `--warnings-as-errors`, so it is fatal
    # there while staying silent on an older local OTP.
    :engram
    |> Application.app_dir("ebin")
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.flat_map(&worker_module/1)
    |> Enum.map(&Code.ensure_loaded!/1)
  end

  defp worker_module(path) do
    case :beam_lib.chunks(String.to_charlist(path), [:attributes]) do
      {:ok, {mod, attributes: attrs}} ->
        behaviours = attrs |> Keyword.get_values(:behaviour) |> List.flatten()
        if Oban.Worker in behaviours, do: [mod], else: []

      _ ->
        []
    end
  end
end
