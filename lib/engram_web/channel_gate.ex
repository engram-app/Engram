defmodule EngramWeb.ChannelGate do
  @moduledoc """
  The socket-side equivalent of the vault-scoped router pipeline's access
  gates. Both `EngramWeb.SyncChannel` and `EngramWeb.CrdtChannel` call
  `check/2` from `join/3`.

  A Plug takes a `conn` and never runs on a socket, so every rule the pipeline
  enforces has to be re-expressed here or it silently does not apply to sync.

  ## What is mirrored, and what is NOT

  The vault scope pipes `:authed_api` (`router.ex:49-60`), which runs
  **eleven** plugs — not three, and not the shorter list an earlier version of
  this doc claimed. Below in PIPELINE order, which is also the order `check/2`
  applies them; derive one from the other only in that order.

  Mirrored:

    * `AccountDeleted`            → `account_deleted` (`deleted_at` only) ✅ #1429
    * `RotationLockCheck`         → `rotation_in_progress` ✅ #1434
    * `RequireOnboarding`         → `onboarding_required` ✅ #1426
    * `RequireActiveSubscription` → `account_suspended` ✅ #1429
    * `BumpActivity`              → liveness stamp ✅ #1429 (see `## Activity`)
    * `RequireApiRpsBudget`       → `api_access_not_available`, but ONLY the
      `cap == 0` case ✅ #1433

  **NOT mirrored — sockets are more permissive than HTTP here:**

    * `RequireApiRpsBudget`'s POSITIVE caps. `CrdtChannel.check_rate/2` is not
      a substitute: it uses fixed compile-time budgets per device and never
      reads the plan, so Starter (10 req/s) and Pro (30 req/s) are metered
      identically and both far above their REST entitlement. #1433.
    * `RequireApiWriteEnabled`. Attempted and REVERTED — **this is a real,
      currently-open entitlement gap, not a no-op**. An earlier version of
      this note claimed "no tier has `api_rps_cap > 0` with
      `api_write_enabled: false`". That is wrong: `Billing.do_effective_limit/2`
      resolves EACH KEY independently (override → env → plan → tier default),
      so a single `user_limit_overrides` row raising a Free user's
      `api_rps_cap` leaves `api_write_enabled` at false. That user is refused
      every non-GET REST route and, after the revert, writes freely over
      `crdt_create` / `crdt_delete` / `sync_update`. The mechanism is
      first-class (dedicated table, pg NOTIFY trigger, OverrideCache, expiry
      sweeper), so treat it as reachable in prod.

      It was reverted because screening `crdt_msg` by payload broke reads
      twice.
      SyncStep1 is a read, but the server answers it with its own SyncStep1
      whose protocol-mandated reply is a SyncStep2, so "block SyncStep2"
      breaks the handshake. Entitlement decided on a wire byte also sits
      ahead of `ensure_room/3`, i.e. ahead of real side effects. If this is
      ever wanted, gate it where the write happens, not on the frame. #1433.
    * `PreAuthRateLimit` (plug 1) — no equivalent, so there is **no join rate
      limiter at all**, which is why `check/2` sits behind the free topic
      ownership match.
    * `DeviceFingerprint` (4) — no equivalent.
    * `EnforceSearchCap` (10) — no equivalent; there is no channel search.

  (`Auth` (2) is not mirrored HERE because `UserSocket.connect/3` already is
  it — that is the eleventh plug, and the one an 11-vs-10 count trips over.)

  `RequireActiveSubscription` collapses into the suspended check — since
  2026-06-07 it passes every tier (Free counts as active) and only rejects
  `suspended_at`. Note `AccountLifecycle` (a different, richer plug) is on the
  user-scoped and onboarding pipelines, NOT this one.

  **Adding a plug to `:authed_api` does not add it here.** Decide explicitly
  whether sync needs it, then either add it to `check/2` or add it to the NOT
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
  alias Engram.Crypto.HMAC
  alias Engram.Crypto.RotationGate
  alias Engram.Logger.Metadata
  alias Engram.Onboarding
  alias Engram.UsageMeters

  require Logger

  @doc """
  `:ok`, or `{:error, payload}` where `payload` is the map to return straight
  from `join/3` (always carries a `:reason`).
  """
  # `api_key` is MANDATORY, deliberately. It defaulted to nil, which made the
  # ungated arity the convenient one: `check(user)` compiled, passed dialyzer
  # and looked complete while silently skipping the Pricing v2 §G join gate —
  # the identical fail-open shape this module exists to prevent one layer up.
  # Pass `socket.assigns[:current_api_key]`; nil is the JWT case.
  @spec check(Engram.Accounts.User.t(), term()) :: :ok | {:error, map()}
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
             :ok <- suspended(fresh) do
          # Liveness stamp sits HERE, between the account gates and the API
          # gates, because that is where `BumpActivity` sits on HTTP
          # (router.ex:57, ahead of `RequireApiRpsBudget` at :58). A Pro user
          # with a PAT integration who downgrades to Free is stamped on every
          # REST call before being refused; stamping after `api_access/2`
          # would leave the socket silent and let `InactivityCleanup` sweep an
          # account generating daily traffic on both transports.
          #
          # It therefore fires when the ACCOUNT passes, not when the join
          # ultimately succeeds — a join later refused for `vault_not_found`
          # still stamps, exactly as an HTTP request to a missing vault does
          # (BumpActivity runs before VaultPlug).
          #
          # KNOWN TRADE-OFF: a Free PAT is refused at `api_access/2` on every
          # join, so an abandoned install reconnecting in a loop keeps its own
          # account looking active and `InactivityCleanup` never sweeps it.
          # HTTP bounds that loop with `PreAuthRateLimit` (plug #1); the socket
          # has no join limiter. Accepted deliberately: the opposite error is
          # soft-DELETING a blocked-but-active account, and data loss beats a
          # stale row. Revisit if a join limiter lands.
          stamp_activity(user_id)
          api_access(fresh, api_key)
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
  # through a `_user` catch-all, so a renamed or retyped column CRASHES here
  # instead of silently passing every account. Same argument
  # `Onboarding.derive_gate/3` makes about its destructuring.
  #
  # This does NOT protect against a narrowed read. Ecto materialises
  # unselected columns as nil, so a `select:`-projected `get_user/1` yields
  # `%User{deleted_at: nil, suspended_at: nil}` and both clauses match
  # cleanly — every suspended and soft-deleted account would pass, with no
  # crash and no test failure. `check/2` must keep loading the FULL row; if
  # the join cost ever motivates a narrower query, gate on a column list, not
  # on these clauses.
  defp deleted(%{deleted_at: %DateTime{}}), do: {:error, %{reason: "account_deleted"}}
  defp deleted(%{deleted_at: nil}), do: :ok

  defp suspended(%{suspended_at: %DateTime{}}), do: {:error, %{reason: "account_suspended"}}
  defp suspended(%{suspended_at: nil}), do: :ok

  # Best-effort, and deliberately so. This is a DB WRITE on a path that was
  # read-only: an exception here would propagate out of `join/3`, kill the
  # channel process, and hand the client a transport error rather than a gate
  # reason — which it then retries, re-attempting the same write. Refusing to
  # sync because we could not record "you were here" is the wrong coupling.
  #
  # Logged rather than swallowed, because a persistently failing stamp is not
  # cosmetic: `InactivityCleanup` reads this column to decide who gets
  # soft-deleted, so silent failure re-creates the very lockout #1429 exists
  # to prevent. It has to be alertable.
  #
  # `:lifecycle`, not `:database` — there is no `:database` category and
  # `with_category/3` RAISES on an unknown atom, so the first version of this
  # handler blew up inside the rescue and killed the join it exists to save.
  # `:reason`, not `:error`, because only allowlisted metadata keys are
  # emitted. `safe_reason/1` / `safe_exit_reason/1` because a raw
  # `%Postgrex.Error{}` renders "Failing row contains (...)" — a row value in
  # a log line whose user_id is HMAC-hashed precisely to avoid that.
  defp stamp_activity(user_id) do
    UsageMeters.touch_active(user_id)
  rescue
    e ->
      Logger.error(
        "activity stamp failed",
        Metadata.with_category(:error, :lifecycle,
          user_id: HMAC.hash_user_id(to_string(user_id)),
          reason: Metadata.safe_reason(e)
        )
      )

      :ok
  catch
    # `rescue` does not catch exits, and a DBConnection checkout timeout exits
    # rather than raising — the single most likely failure here.
    kind, reason ->
      Logger.error(
        "activity stamp exited",
        Metadata.with_category(:error, :lifecycle,
          user_id: HMAC.hash_user_id(to_string(user_id)),
          reason_label: to_string(kind),
          reason: Metadata.safe_exit_reason(reason)
        )
      )

      :ok
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
  # ONLY the `cap == 0` half is mirrored. `CrdtChannel.check_rate/2` is NOT
  # the socket's `api_rps_cap`: it uses fixed compile-time budgets per device
  # and never reads the plan, so a Starter key entitled to 10 req/s over REST
  # sustains far more over the socket, and Starter and Pro are metered
  # identically. See the NOT-mirrored list above.
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
