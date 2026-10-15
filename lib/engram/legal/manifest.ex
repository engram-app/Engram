defmodule Engram.Legal.Manifest do
  @moduledoc """
  The vendored `priv/legal/legal-manifest.json`: document => version => hash,
  the same bytes the frontend bundles (#318). What THIS build can render.

  Its own module so the `File.read!` sobelow pins in `.sobelow-skips` never
  moves when a legal publish edits `Engram.Legal.Seeder`.
  """

  @spec read() :: %{String.t() => %{String.t() => String.t()}}
  def read do
    path = Application.app_dir(:engram, "priv/legal/legal-manifest.json")
    path |> File.read!() |> Jason.decode!()
  end

  @doc "The newest version of `document` this build ships, or nil."
  @spec newest(String.t()) :: String.t() | nil
  def newest(document),
    do: read() |> Map.get(document, %{}) |> Map.keys() |> Enum.max(fn -> nil end)
end
