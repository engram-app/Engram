defmodule Engram.Telemetry.InstallPings do
  @moduledoc "Records self-host census pings (SaaS collector side)."
  alias Engram.Repo
  alias Engram.Telemetry.InstallPing

  @doc "Upserts by install id; a repeat ping refreshes the fields and `updated_at`."
  def record(params) do
    %InstallPing{}
    |> InstallPing.changeset(params)
    |> Repo.insert(
      on_conflict: {:replace, [:version, :os, :arch, :runtime, :updated_at]},
      conflict_target: :id,
      skip_tenant_check: true
    )
  end
end
