defmodule EngramWeb.ChannelGate do
  @moduledoc """
  The socket-side equivalent of the vault-scoped router pipeline's access
  gates. Both `EngramWeb.SyncChannel` and `EngramWeb.CrdtChannel` call
  `check/1` from `join/3`.

  A Plug takes a `conn` and never runs on a socket, so every rule the pipeline
  enforces has to be re-expressed here or it silently does not apply to sync.
  ## What is mirrored, and what is NOT

  The vault scope pipes `:authed_api` (`router.ex:49-60`), which runs
  **eleven** plugs. This module mirrors three of them:

    * `AccountDeleted`            → 410 `account_deleted` (`deleted_at` only) ✅
    * `RequireOnboarding`         → 403 `onboarding_required` ✅ (#1426)
    * `RequireActiveSubscription` → 402 `account_suspended` ✅ (#1429)

    * `RotationLockCheck`         → 423 `rotation_in_progress` ✅ (#1434)
    * `RequireApiRpsBudget`       → `api_access_not_available` at join for a
      key whose tier has `api_rps_cap: 0` ✅ (#1433)
    * `RequireApiWriteEnabled`    → WRITE frames only ✅ (#1433), see
      `api_write_blocked?/2` and `CrdtChannel`'s `@write_events` clause

  plus `BumpActivity`'s liveness stamp (see `## Activity`).

  **NOT mirrored — sockets are more permissive than HTTP here:**

    * `EnforceSearchCap`, `DeviceFingerprint`, `PreAuthRateLimit` — no channel
      equivalent; `PreAuthRateLimit` notably means there is **no join rate
      limiter** at all.

  `RequireActiveSubscription` collapses into the suspended check — since
  2026-06-07 it passes every tier (Free counts as active) and only rejects
  `suspended_at`. Note `AccountLifecycle` (a different, richer plug) is on the
  user-scoped and onboarding pipelines, NOT this one.

  **Adding a plug to `:authed_api` does not add it here.** Decide explicitly
  whether sync needs it, then either add it to `check/1` or add it to the NOT
  list above with a reason.

  ## Why `user:` is not gated

  `EngramWeb.UserChannel` deliberately does NOT call this. It carries
  `vault_created` / `vault_populated` (the FTUX vault screen blocks on them)
  and `subscription_activated`, and no note content — only ids, names, and
  plan metadata.

  The justification is **suspension-specific**: a suspended user must be able
  to pay their way out, which is why `AccountLifecycle` allowlists
  `/api/billing/*`; `user:` is the socket equivalent. It does NOT extend to
  deleted accounts, for whom HTTP is terminal with no exemptions — a
  soft-deleted account can still join `user:` today. That is an open gap, not
  a decision: tracked in #1435.

  ## Activity

  A passing join also stamps `usage_meters.last_active_at` via
  `UsageMeters.touch_active/1` (debounced), mirroring
  `EngramWeb.Plugs.BumpActivity` on the HTTP side.

  This is not incidental — it is load-bearing for the gate above.
  `Engram.Workers.InactivityCleanup` soft-deletes Free accounts whose stamp
  has aged past the window, and that stamp was previously written ONLY by the
  request plug. A plugin user who syncs daily over CRDT and rarely touches
  REST therefore aged into the sweep while in constant active use. Before
  lifecycle was enforced here that was invisible (sync kept working); with it
  enforced, the same user would get a permanent `account_deleted` refusal on a
  live account. Porting the enforcement half of a pipeline without the
  liveness half turns a latent mis-classification into user-visible data loss.

  ## Freshness

  Lifecycle is read from a **fresh row on every join**, never from the socket's
  `current_user` (frozen at `connect/3`) and never from `Onboarding.GateCache`
  (a 60s PASS cache). An admin suspension must bite on the very next join:
  `SessionInvalidator` kills the live socket, but the JWT stays valid and the
  client reconnects within seconds.
  """

  alias Engram.Accounts
  alias Engram.Billing
  alias Engram.Crypto.RotationGate
  alias Engram.Onboarding
  alias Engram.UsageMeters

  @doc """
  `:ok`, or `{:error, payload}` where `payload` is the map to return straight
  from `join/3` (always carries a `:reason`).
  """
  @spec check(Engram.Accounts.User.t(), term()) :: :ok | {:error, map()}
  def check(user, api_key \\ nil)

  def check(%Engram.Accounts.User{id: user_id}, api_key) do
    # One read, shared by both checks — `gate/2` is told not to re-read.
    #
    # No `|| socket_user` fallback: `Accounts.Lifecycle.hard_delete/2` removes
    # the row outright, and falling back to the socket's frozen `current_user`
    # would be fail-OPEN — that struct predates the deletion and carries no
    # `deleted_at`, so a purged account with a still-valid JWT would keep
    # syncing. HTTP fails closed here (`Plugs.Auth` cannot resolve a missing
    # user and 401s); the socket must not be more permissive.
    case Accounts.get_user(user_id) do
      nil ->
        {:error, %{reason: "account_deleted"}}

      fresh ->
        # Precedence mirrors `:authed_api` exactly (router.ex:52-56):
        # AccountDeleted -> RotationLockCheck -> RequireOnboarding ->
        # RequireActiveSubscription. Suspension therefore comes AFTER
        # onboarding, so an account suspended mid-signup reports the same
        # reason on both transports. Rotation reuses the row already loaded
        # here via `check_user/1`, so it costs no extra query.
        with :ok <- deleted(fresh),
             :ok <- rotation(fresh),
             :ok <- onboarding(fresh),
             :ok <- suspended(fresh),
             :ok <- api_access(fresh, api_key) do
          # Liveness, mirroring `EngramWeb.Plugs.BumpActivity` — see the
          # `## Activity` note above. Only on a PASS: a refused client
          # retrying forever must not keep its own account looking alive.
          UsageMeters.touch_active(user_id)
        end
    end
  end

  @doc """
  Deletion-only check, for `user:`.

  `user:` is exempt from suspension and onboarding on purpose (see the
  moduledoc) but NOT from deletion: `AccountDeleted`'s clause runs ahead of
  the suspension allowlist and HTTP is terminal for a deleted account —
  "410 Gone on every endpoint, no exemptions". A purged row counts as deleted.
  """
  @spec check_not_deleted(Engram.Accounts.User.t()) :: :ok | {:error, map()}
  def check_not_deleted(%Engram.Accounts.User{id: user_id}) do
    case Accounts.get_user(user_id) do
      nil -> {:error, %{reason: "account_deleted"}}
      %{deleted_at: %DateTime{}} -> {:error, %{reason: "account_deleted"}}
      %{deleted_at: nil} -> :ok
    end
  end

  # Each of these matches STRICTLY on the field it gates rather than falling
  # through a `_user` catch-all. A catch-all is fail-OPEN keyed on field
  # presence: rename the column, narrow the read to a projection, or change
  # the type away from `:utc_datetime_usec`, and the guard stops matching
  # while every account silently passes — no compile error, no test failure.
  # Same argument `Onboarding.derive_gate/3` makes about its destructuring.
  # A missing field should crash, not pass.
  defp deleted(%{deleted_at: %DateTime{}}), do: {:error, %{reason: "account_deleted"}}
  defp deleted(%{deleted_at: nil}), do: :ok

  defp suspended(%{suspended_at: %DateTime{}}), do: {:error, %{reason: "account_suspended"}}
  defp suspended(%{suspended_at: nil}), do: :ok

  @doc """
  Pricing v2 §G write half, mirroring `EngramWeb.Plugs.RequireApiWriteEnabled`
  (#1433). True when this socket's caller may not issue write frames.

  JWT callers are exempt (the web UI hides write affordances for tiers that
  lack the feature), matching the plug. Evaluated once at join and stashed in
  assigns so the per-frame check is a pattern match, not a query — an
  entitlement change takes effect on the next join, same as `plan_state`.
  """
  @spec api_write_blocked?(Engram.Accounts.User.t(), term()) :: boolean()
  def api_write_blocked?(_user, nil), do: false

  def api_write_blocked?(user, _api_key) do
    Billing.check_feature(user, :api_write_enabled) != :ok
  end

  # Pricing v2 §G, mirroring `RequireApiRpsBudget` (#1433). That plug has no
  # GET exemption, so for an API-key caller it gates EVERY request — and
  # Free's `api_rps_cap` default is 0. A Free key therefore cannot make a
  # single REST call, and must not be able to open a sync socket and read the
  # whole vault instead.
  #
  # The exemption keys on the key being non-nil, NOT on the assign existing.
  # The plug uses `not is_map_key(assigns, :current_api_key)`, but
  # `UserSocket.accept/4` ALWAYS sets that key (nil for JWT) — porting the
  # guard literally would gate every web and plugin user on the platform.
  #
  # Positive caps are metered per-frame by `CrdtChannel.check_rate/2`; this is
  # the "may you use the API at all" half.
  defp api_access(_user, nil), do: :ok

  defp api_access(user, _api_key) do
    case Billing.effective_limit(user, :api_rps_cap) do
      0 -> {:error, %{reason: "api_access_not_available", upgrade_url: "/#settings/billing"}}
      _ -> :ok
    end
  end

  # `check_user/1`, not `check/1` — the row is already loaded, so this costs
  # no query. `CrdtChannel` used to open-code `RotationGate.check/1`, which
  # re-read the same row; `SyncChannel` had no check at all (#1434).
  defp rotation(user) do
    case RotationGate.check_user(user) do
      :ok -> :ok
      {:error, :rotation_in_progress} -> {:error, %{reason: "rotation_in_progress"}}
    end
  end

  defp onboarding(user) do
    case Onboarding.gate(user, fresh: true) do
      :ok ->
        :ok

      {:error, missing, next_step} ->
        {:error, %{reason: "onboarding_required", missing: missing, next_step: next_step}}
    end
  end
end
