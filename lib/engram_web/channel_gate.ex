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

  plus `BumpActivity`'s liveness stamp (see `## Activity`), and `CrdtChannel`
  separately open-codes `RotationGate.check/1`.

  **NOT mirrored — sockets are more permissive than HTTP here:**

    * `RequireApiWriteEnabled` / `RequireApiRpsBudget` — a Free-tier PAT is
      402'd and 429'd on `POST /api/notes` but writes freely over `crdt_msg`.
      Tracked in #1433. Port trap: both exempt via
      `not is_map_key(assigns, :current_api_key)`, and `UserSocket.accept/4`
      ALWAYS sets that key (nil for JWT), so a literal port gates every JWT
      socket.
    * `RotationLockCheck` — `CrdtChannel` has an equivalent, `SyncChannel` has
      none. Tracked in #1434.
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
  alias Engram.Onboarding
  alias Engram.UsageMeters

  @doc """
  `:ok`, or `{:error, payload}` where `payload` is the map to return straight
  from `join/3` (always carries a `:reason`).
  """
  @spec check(Engram.Accounts.User.t()) :: :ok | {:error, map()}
  def check(%Engram.Accounts.User{id: user_id}) do
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
        with :ok <- lifecycle(fresh),
             :ok <- onboarding(fresh) do
          # Liveness, mirroring `EngramWeb.Plugs.BumpActivity` — see the
          # `## Activity` note above. Only on a PASS: a refused client
          # retrying forever must not keep its own account looking alive.
          UsageMeters.touch_active(user_id)
        end
    end
  end

  # Deleted takes precedence over suspended, mirroring
  # `EngramWeb.Plugs.AccountLifecycle`.
  defp lifecycle(%{deleted_at: %DateTime{}}), do: {:error, %{reason: "account_deleted"}}
  defp lifecycle(%{suspended_at: %DateTime{}}), do: {:error, %{reason: "account_suspended"}}

  # Strictly `nil, nil` rather than a `_user` catch-all. A catch-all is
  # fail-OPEN keyed on field presence: rename either column, narrow the read
  # to a projection, or change the type away from `:utc_datetime_usec`, and
  # both guard clauses above stop matching while every account silently
  # passes the lifecycle gate — no compile error, no test failure. This is
  # the same argument `Onboarding.derive_gate/3` makes about its own
  # destructuring. A missing field should crash, not pass.
  defp lifecycle(%{deleted_at: nil, suspended_at: nil}), do: :ok

  defp onboarding(user) do
    case Onboarding.gate(user, fresh: true) do
      :ok ->
        :ok

      {:error, missing, next_step} ->
        {:error, %{reason: "onboarding_required", missing: missing, next_step: next_step}}
    end
  end
end
