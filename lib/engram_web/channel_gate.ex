defmodule EngramWeb.ChannelGate do
  @moduledoc """
  The socket-side equivalent of the vault-scoped router pipeline's access
  gates. Both `EngramWeb.SyncChannel` and `EngramWeb.CrdtChannel` call
  `check/1` from `join/3`.

  A Plug takes a `conn` and never runs on a socket, so every rule the pipeline
  enforces has to be re-expressed here or it silently does not apply to sync.
  The pipeline runs three (`router.ex`):

    * `AccountLifecycle`        → 410 `account_deleted` / 403 `account_suspended`
    * `RequireOnboarding`       → 403 `onboarding_required`
    * `RequireActiveSubscription` → 402 `account_suspended`

  #1426 ported only the middle one; #1429 ported the rest. `RequireActiveSubscription`
  collapses into the suspended check — since 2026-06-07 it passes every tier
  (Free counts as active) and only rejects `suspended_at`.

  **Adding a gate to the vault pipeline does not add it here.** If you add a
  plug to `router.ex`, decide explicitly whether sync needs it and add it to
  `check/1`.

  ## Why `user:` is not gated

  `EngramWeb.UserChannel` deliberately does NOT call this. It carries
  `vault_created` / `vault_populated` (the FTUX vault screen blocks on them)
  and `subscription_activated`. `AccountLifecycle` exempts `/api/billing/*` so
  a suspended user can pay their way out; `user:` is the socket equivalent of
  that exemption. Gating it would strand exactly the users who are trying to
  fix their state. It carries no note content — only ids, names, and plan
  metadata.

  ## Freshness

  Lifecycle is read from a **fresh row on every join**, never from the socket's
  `current_user` (frozen at `connect/3`) and never from `Onboarding.GateCache`
  (a 60s PASS cache). An admin suspension must bite on the very next join:
  `SessionInvalidator` kills the live socket, but the JWT stays valid and the
  client reconnects within seconds.
  """

  alias Engram.Accounts
  alias Engram.Onboarding

  @doc """
  `:ok`, or `{:error, payload}` where `payload` is the map to return straight
  from `join/3` (always carries a `:reason`).
  """
  @spec check(Engram.Accounts.User.t()) :: :ok | {:error, map()}
  def check(%{id: user_id}) do
    # One read, shared by both checks — `gate/2` is told not to re-read.
    #
    # No `|| socket_user` fallback: `Accounts.Lifecycle.hard_delete/2` removes
    # the row outright, and falling back to the socket's frozen `current_user`
    # would be fail-OPEN — that struct predates the deletion and carries no
    # `deleted_at`, so a purged account with a still-valid JWT would keep
    # syncing. HTTP fails closed here (`Plugs.Auth` cannot resolve a missing
    # user and 401s); the socket must not be more permissive.
    case Accounts.get_user(user_id) do
      nil -> {:error, %{reason: "account_deleted"}}
      fresh -> with :ok <- lifecycle(fresh), do: onboarding(fresh)
    end
  end

  # Deleted takes precedence over suspended, mirroring
  # `EngramWeb.Plugs.AccountLifecycle`.
  defp lifecycle(%{deleted_at: %DateTime{}}), do: {:error, %{reason: "account_deleted"}}
  defp lifecycle(%{suspended_at: %DateTime{}}), do: {:error, %{reason: "account_suspended"}}
  defp lifecycle(_user), do: :ok

  defp onboarding(user) do
    case Onboarding.gate(user, fresh: true) do
      :ok ->
        :ok

      {:error, missing, next_step} ->
        {:error, %{reason: "onboarding_required", missing: missing, next_step: next_step}}
    end
  end
end
