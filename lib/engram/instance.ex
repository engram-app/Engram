defmodule Engram.Instance do
  @moduledoc """
  Instance-global settings (self-host). Singleton row identified by `@singleton_id`.

  * `registration_mode` controls self-registration: closed | invite_only | open.
  * `bootstrap_completed_at` records when the claim window closed — the first
    signup writes it atomically inside the same advisory-locked transaction
    that creates the admin user. Subsequent signups read it via
    `bootstrap_pending?/0` (one PK SELECT, independent of user count).
  """
  alias Engram.Instance.InstanceSettings
  alias Engram.Repo

  @default_mode "invite_only"

  # Sentinel uuid for the single instance_settings row. The schema has no DB-level
  # CHECK constraint (would require literal-id comparison incompatible with uuidv7
  # defaults); singleton-ness is enforced by always writing under this sentinel.
  @singleton_id "00000000-0000-0000-0000-000000000000"

  @doc """
  Returns the current registration mode. Falls back to the application-configured
  default (`:default_registration_mode`, settable via the `ENGRAM_DEFAULT_REGISTRATION_MODE`
  env var) when no instance_settings row exists yet. The app-env default lets CI
  pin "open" without rewriting every e2e fixture; production keeps "invite_only".
  """
  def registration_mode do
    case Repo.get(InstanceSettings, @singleton_id, skip_tenant_check: true) do
      nil -> Application.get_env(:engram, :default_registration_mode, @default_mode)
      %InstanceSettings{registration_mode: mode} -> mode
    end
  end

  @doc """
  True until the first signup commits the bootstrap row. After that, returns
  false forever for this instance — a single PK SELECT, no `COUNT(users)` tax.
  Used by the public `/api/auth/bootstrap` endpoint and by the controller gate
  in `LocalAuthController.check_registration_allowed/1`.
  """
  def bootstrap_pending? do
    case Repo.get(InstanceSettings, @singleton_id, skip_tenant_check: true) do
      nil -> true
      %InstanceSettings{bootstrap_completed_at: nil} -> true
      _ -> false
    end
  end

  @doc """
  Stamps the singleton row with `bootstrap_completed_at = now()`. MUST be
  called inside the bootstrap advisory lock and only when `bootstrap_pending?/0`
  returned true on a direct read in the same transaction — that way concurrent
  signups serialize, the second one sees `bootstrap_pending? == false`, and
  this never gets called twice.
  """
  def mark_bootstrap_complete(now \\ DateTime.utc_now(:second)) do
    default_mode = Application.get_env(:engram, :default_registration_mode, @default_mode)

    %InstanceSettings{id: @singleton_id}
    |> InstanceSettings.changeset(%{
      registration_mode: default_mode,
      bootstrap_completed_at: now
    })
    |> Repo.insert(
      on_conflict: [
        set: [
          bootstrap_completed_at: now,
          updated_at: now
        ]
      ],
      conflict_target: :id,
      skip_tenant_check: true
    )
  end

  @doc "Sets the registration mode. Upserts the singleton row at @singleton_id."
  def set_registration_mode(mode) when is_binary(mode) do
    if mode in InstanceSettings.modes() do
      %InstanceSettings{id: @singleton_id}
      |> InstanceSettings.changeset(%{registration_mode: mode})
      |> Repo.insert(
        on_conflict: [
          set: [
            registration_mode: mode,
            updated_at: DateTime.utc_now(:second)
          ]
        ],
        conflict_target: :id,
        skip_tenant_check: true
      )
    else
      {:error, :invalid_mode}
    end
  end
end
