defmodule Engram.Telemetry.InstallPing do
  @moduledoc """
  One row per self-host install that has pinged the collector. The enums mirror
  what `Engram.Telemetry.Heartbeat` can send; anything else is rejected, so a
  hostile caller cannot store free text here.
  """
  use Engram.Schema
  import Ecto.Changeset

  schema "install_pings" do
    field :version, :string
    field :os, :string
    field :arch, :string
    field :runtime, :string
    timestamps(type: :utc_datetime)
  end

  @fields [:id, :version, :os, :arch, :runtime]
  @oses ~w(linux darwin windows other)
  @arches ~w(amd64 arm64 other)
  @runtimes ~w(docker source)

  def oses, do: @oses
  def arches, do: @arches
  def runtimes, do: @runtimes

  def changeset(ping, attrs) do
    ping
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_length(:version, max: 32)
    |> validate_inclusion(:os, @oses)
    |> validate_inclusion(:arch, @arches)
    |> validate_inclusion(:runtime, @runtimes)
  end
end
