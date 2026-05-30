defmodule Engram.Instance do
  @moduledoc """
  Instance-global settings (self-host). Singleton row at id=1.
  registration_mode controls self-registration: closed | invite_only | open.
  """
  alias Engram.Instance.InstanceSettings
  alias Engram.Repo

  @default_mode "invite_only"

  @doc "Returns the current registration mode, defaulting to invite_only."
  def registration_mode do
    case Repo.get(InstanceSettings, 1) do
      nil -> @default_mode
      %InstanceSettings{registration_mode: mode} -> mode
    end
  end

  @doc "Sets the registration mode. Upserts the singleton row at id=1."
  def set_registration_mode(mode) when is_binary(mode) do
    if mode in InstanceSettings.modes() do
      %InstanceSettings{id: 1}
      |> InstanceSettings.changeset(%{registration_mode: mode})
      |> Repo.insert(
        on_conflict: [
          set: [
            registration_mode: mode,
            updated_at: DateTime.utc_now(:second)
          ]
        ],
        conflict_target: :id
      )
    else
      {:error, :invalid_mode}
    end
  end
end
