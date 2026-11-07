defmodule Engram.Release.Floor do
  @moduledoc """
  The rollback floor: the oldest release prod may be rolled back to. A
  release whose changes an older one cannot read (a write stop, a contract)
  may ship only once the floor is at or above the release it needs.

  One source of truth, `priv/release_floor` (one line, a `release-vX.Y.Z`
  tag), read here at compile time and by `scripts/check_release_floor.sh`,
  which a deploy runs against main's copy. Raising the floor is a PR changing
  that file: an owner decision (Todd), because it removes rollback targets.
  `docs/context/rollback-floor.md` has the procedure and what the deploy
  check can and cannot stop.

  Code that needs a floor states it with a test: `assert Floor.at_least?("release-vX.Y.Z")`.
  That test is red while the file says less, so the code cannot merge first.
  Nothing reads the floor at runtime: a self-host install that jumps several
  releases is made correct by each release's own runtime gates.
  """

  @path Path.expand("../../../priv/release_floor", __DIR__)
  @external_resource @path

  @tag @path |> File.read!() |> String.trim()

  unless @tag =~ ~r/\Arelease-v\d+\.\d+\.\d+\z/,
    do: raise(CompileError, description: "priv/release_floor: not a release-vX.Y.Z tag: #{@tag}")

  @doc "The floor's release tag, e.g. `\"release-v0.76.0\"`."
  @spec tag() :: String.t()
  def tag, do: @tag

  @doc "The floor's version."
  @spec version() :: Version.t()
  def version, do: to_version(@tag)

  @doc "Whether the floor is at or above `tag` (a `release-vX.Y.Z` tag)."
  @spec at_least?(String.t()) :: boolean()
  def at_least?(tag), do: Version.compare(version(), to_version(tag)) != :lt

  defp to_version("release-v" <> v), do: Version.parse!(v)
end
